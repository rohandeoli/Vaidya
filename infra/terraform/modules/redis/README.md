# Redis (ElastiCache) module

Managed Redis for session storage, rate-limit counters, idempotency keys, and worker locks. Lives in the data subnets alongside RDS. Encrypted at rest with our CMK, encrypted in transit with TLS, AUTH-token protected.

---

## The one rule that shapes this entire module

**No PHI in Redis.** From `CLAUDE.md` hard rule #2:

> Sessions and rate limit counters only.

Biomarker values, report text, patient names, anything from an uploaded PDF — none of it goes here. If you're tempted to cache "the parsed report for faster reads," cache the *report ID* and re-fetch from Postgres. The cache holds keys; Postgres holds the data.

This rule is why we run the cluster fairly small, keep snapshots minimal, and don't bother with cross-region anything. The blast radius of a Redis compromise is "an attacker can flush the session store and force everyone to re-login" — annoying, not catastrophic.

---

## What lives in Redis

| Key pattern | Value | TTL | Purpose |
|---|---|---|---|
| `session:{user_id}` | JWT validation cache, last-active timestamp | 24h | Avoid re-validating JWT signature on every request |
| `rate:{user_id}:{endpoint}` | request count (integer) | 1m – 1h | Per-endpoint rate limiting |
| `idem:{idempotency_key}` | response hash | 10m | Block duplicate report uploads |
| `lock:report:{report_id}` | worker ID + timestamp | 5m | Prevent two Lambda invocations from processing the same SQS message |

Notice what's missing: no chunk embeddings (those live in Postgres + pgvector), no Claude response text, no extracted biomarker values, no user PII.

---

## Cluster shape

| | Staging | Prod |
|---|---|---|
| Engine | Redis 7.1 | Redis 7.1 |
| Node type | `cache.t4g.micro` | `cache.t4g.small` |
| Nodes | 1 (primary only) | 2 (primary + 1 replica) |
| Automatic failover | off | on |
| Multi-AZ | off | on |
| Snapshot retention | 1 day | 1 day |
| Approx. cost | $13/mo | $54/mo |

We use a **single replication group, cluster mode disabled** — no sharding. The working set is well under the cache size; sharding adds operational complexity we don't need.

---

## Encryption

Three knobs, all on:

| Knob | Setting | What it means |
|---|---|---|
| `at_rest_encryption_enabled` | `true` | EBS volume + snapshots encrypted via our `app_key` CMK |
| `transit_encryption_enabled` | `true` | All client connections must be TLS |
| `auth_token` | from `medical-ai/{env}/redis/auth-token` secret | AUTH command required after connecting; rejects clients that don't authenticate |

Transit encryption is what forces every client to be TLS-aware. Plaintext clients fail at the TCP handshake, before sending any data.

---

## Networking

```
                              VPC (10.0.0.0/16)
                              ─────────────────
                              data subnet                ← no internet route at all
                              ┌─────────────────────┐
Fargate API ──────────────────┤                     │
(private subnet)              │   ElastiCache       │
                              │   primary           │
Lambda worker ────────────────┤   + replica (prod)  │
(private subnet)              │                     │
                              └─────────────────────┘
                                       ↑
Bastion ───────────────────────────────┘
(staging only)                        port 6379

Security group rules:
  ingress 6379: from API SG  (added by compute module when it lands)
  ingress 6379: from worker SG (added by compute module when it lands)
  ingress 6379: from bastion SG (added by bastion module — staging only)
  egress:       none
```

The Redis SG starts empty. Each caller adds its own ingress rule referencing the Redis SG's ID — same pattern we use for RDS.

---

## Day-to-day usage

### Connect to staging Redis from your laptop

Terminal 1 — tunnel:
```bash
./scripts/db-tunnel.sh staging redis
```

Default local port is 6379. To override (if you already have a local Redis on 6379):
```bash
./scripts/db-tunnel.sh staging redis 16379
```

Terminal 2 — fetch the AUTH token and connect:
```bash
AUTH=$(aws secretsmanager get-secret-value \
  --secret-id medical-ai/staging/redis/auth-token \
  --query SecretString --output text)

redis-cli -h localhost -p 6379 --tls --insecure -a "$AUTH"
```

The flags matter:
- `--tls` — speak TLS (transit encryption is enforced)
- `--insecure` — skip cert verification (we're connecting to `localhost` but the server cert is for the ElastiCache hostname). Safe on the tunnel; not safe in app code.
- `-a` — send the AUTH command with the token

### Install redis-cli with TLS support

The Homebrew default `redis` formula includes TLS:
```bash
brew install redis
redis-cli --version
```

If `redis-cli --tls` errors with "unrecognised option", you have a TLS-less build. Reinstall:
```bash
brew reinstall redis
```

### Use a GUI

Most modern Redis GUIs (RedisInsight, Another Redis Desktop Manager, TablePlus) speak TLS. Settings:

| Field | Value |
|---|---|
| Host | `localhost` |
| Port | `6379` (or whatever the tunnel uses) |
| Username | (leave blank — we don't use Redis 6 ACLs) |
| Password / AUTH | from `aws secretsmanager get-secret-value` |
| Use TLS | yes |
| Skip cert verification | yes (because we hit `localhost`) |

---

## Sanity checks (post-apply)

```redis
PING
> PONG

INFO replication
# staging: role:master, connected_slaves:0
# prod:    role:master, connected_slaves:1

CONFIG GET maxmemory-policy
# 1) "maxmemory-policy"
# 2) "allkeys-lru"          ← our override; if "noeviction", parameter group didn't apply

CONFIG GET maxmemory
# Should be a non-zero number — ElastiCache sets this from the node type

CLIENT LIST
# Should show your one connection (the redis-cli tunnel)
```

If `CONFIG GET maxmemory-policy` returns `noeviction`, the parameter group didn't attach correctly. Re-check `terraform plan` and the AWS console (ElastiCache → Parameter groups).

---

## Security model

| Layer | Control |
|---|---|
| Network | Private data subnet, no internet route. SG starts with no ingress. |
| Transport | TLS required — plaintext connections refused at handshake |
| Authentication | AUTH token from Secrets Manager. 64 chars, alphanumeric + limited specials |
| Authorization | All-or-nothing. We're not using Redis 6 ACLs (per-key permissions) — not worth the complexity at this scale |
| Encryption at rest | CMK from kms module — same key as RDS storage |
| Audit | CloudTrail logs `ModifyReplicationGroup`, `RebootCacheCluster`, etc. Per-command logging is not enabled (would be `slow-log` + custom CloudWatch shipping) |

### Trust boundary

The Redis instance holds **no PHI**. If the AUTH token leaks, an attacker can:
- Read all session IDs (use to impersonate active users — bad, but bounded to the 24h session TTL)
- Read all rate-limit counters (useless)
- Flush the cache (forces re-login for everyone — annoying)

They **cannot** access PHI through Redis — there's none stored.

This is why the AUTH token rotation flow is "important but not urgent" — unlike the RDS master password (which protects PHI), this protects session state.

---

## AUTH token rotation

The `lifecycle.ignore_changes = [auth_token]` on the replication group means Terraform will *not* touch the token after creation. Rotation is a deliberate two-step process.

### Manual rotation (when you suspect compromise)

```bash
# 1. Generate new token (or let TF re-generate via the secrets module)
NEW_TOKEN="$(openssl rand -hex 32)"

# 2. Update the secret
aws secretsmanager put-secret-value \
  --secret-id medical-ai/staging/redis/auth-token \
  --secret-string "$NEW_TOKEN"

# 3. Apply the new token to the cluster — ElastiCache supports rolling rotation
aws elasticache modify-replication-group \
  --replication-group-id medical-ai-staging \
  --auth-token "$NEW_TOKEN" \
  --auth-token-update-strategy ROTATE \
  --apply-immediately
```

The `ROTATE` strategy keeps the old token valid alongside the new one until you run again with `SET` strategy to finalize. This means a running API service can be deployed with the new token without dropping connections, then the old token is revoked.

For an emergency (compromised token, force kick everyone), use `--auth-token-update-strategy SET` directly — immediate cutover, will close existing connections.

### What never to do

- **Don't** modify `auth_token` in the Terraform config and apply — the `ignore_changes` will silently swallow your edit, leaving the cluster with the old token and your config out of sync.
- **Don't** run `--auth-token-update-strategy DELETE` — that removes auth entirely. ElastiCache won't actually let you do this when transit encryption is on, but mentioning it for completeness.

---

## Cost breakdown

### Staging
| Component | Monthly |
|---|---|
| 1× cache.t4g.micro | $11.97 |
| ~20 MB storage | $0 (free tier limits) |
| Snapshots (1 day) | < $0.05 |
| Data transfer in/out (intra-AZ) | free |
| **Total** | **~$13/mo** |

### Prod
| Component | Monthly |
|---|---|
| 2× cache.t4g.small (primary + replica) | $47.88 |
| Snapshots (1 day) | < $0.05 |
| Inter-AZ replication traffic | $5-10 (depends on write rate) |
| **Total** | **~$54/mo** |

Stop-when-not-in-use is **not supported** for ElastiCache (unlike EC2 / RDS). The cluster runs 24/7 once created. To save money on staging when truly idle, you'd have to destroy and re-create — a `terraform destroy -target=module.redis` and `terraform apply` cycle is ~10 minutes total.

---

## Lifecycle and patching

- `auto_minor_version_upgrade = true` — AWS applies 7.1.x patches during the maintenance window
- Major version upgrades (7 → 8 when it lands) are always manual: bump `engine_version`, re-apply, accept an in-place upgrade (a few seconds of downtime)
- Parameter group changes that aren't `Immediate` apply at the next maintenance window — if you want immediate, set `apply_immediately = true` on the replication group (we don't, by default)

---

## Things you do NOT do here

- **Don't cache PHI.** Re-stating because it's the only rule that matters. If you find code doing `redis.set("report:123", report_json)`, that's a bug.
- **Don't add a non-TLS listener.** Some tutorials suggest disabling transit encryption "for simplicity in dev." Don't — staging is a small mirror of prod, and the gap teaches bad habits.
- **Don't set `notify-keyspace-events`** unless you actually use keyspace notifications. Costs cluster CPU per write.
- **Don't store anything large** (> 10 KB per key). Redis is a cache, not a blob store. Use S3 for blobs.
- **Don't run `FLUSHALL` in prod.** It clears all sessions; everyone gets logged out. Use `FLUSHDB` on a specific database, and only when you mean it.

---

## Troubleshooting

### `Could not connect to Redis at localhost:6379: SSL_connect() failed`
You're hitting plaintext on a TLS-required server, or vice versa. Recheck:
- Are you passing `--tls` to redis-cli?
- Is the tunnel running? (Terminal 1)
- Is your `redis-cli` actually TLS-capable? `redis-cli --tls --help` should not error.

### `(error) WRONGPASS invalid username-password pair`
The AUTH token is wrong. Re-fetch:
```bash
aws secretsmanager get-secret-value \
  --secret-id medical-ai/staging/redis/auth-token \
  --query SecretString --output text | pbcopy
```
Then paste into `redis-cli -a` (or as the password field in your GUI). Note: secrets values can contain `$` and other shell-special characters — use `pbcopy` or always quote the variable.

### `CONFIG GET maxmemory-policy` returns `noeviction`
The parameter group didn't attach, or the cluster is using the default parameter group. Check the AWS console:
- ElastiCache → Replication groups → medical-ai-staging → Parameter group should say `medical-ai-redis-staging-r7`
- If it says `default.redis7`, re-run `terraform apply` — sometimes the first apply silently uses the default and only attaches on a subsequent apply

### Tunnel opens but commands hang for 30+ seconds before responding
TLS handshake over SSM is slow on the first connection. Subsequent commands should be fast. If they remain slow, the issue is the bastion's network path — check NAT gateway status in the VPC dashboard.

### `READONLY You can't write against a read only replica`
You connected to the reader endpoint by mistake. Use `redis_primary_endpoint` (writes) — the tunnel script defaults to that. The reader endpoint only matters in prod where there are actual replicas.

### Apply hangs at "Still creating... (10m elapsed)"
ElastiCache creation is slow — single-node ~6-8 min, multi-AZ ~10-15 min. Wait. If it goes past 20 min, check the ElastiCache console for "Failed" status — usually a parameter group misconfiguration.

---

## Decommissioning

To remove Redis from staging permanently:

1. Remove `module "redis"` from `envs/staging/main.tf`.
2. Remove `redis_security_group_id = module.redis.security_group_id` from the bastion block (and `redis_security_group_id` from `modules/bastion/variables.tf` if you also want to drop the input).
3. Remove the Redis outputs from `envs/staging/outputs.tf`.
4. `terraform apply` — destroys the replication group (takes ~5 min), parameter group, SG, and the ingress rule on the (now-removed) Redis SG from the bastion module.

The cache disappears; any in-flight sessions are dropped. Users re-authenticate on next request.

---

## Cross-references

- The bastion module owns the ingress rule from bastion → Redis: `infra/terraform/modules/bastion/main.tf` → `aws_security_group_rule.redis_from_bastion`
- The secrets module owns the AUTH token secret: `infra/terraform/modules/secrets/main.tf` → `aws_secretsmanager_secret.redis_auth_token`
- The tunnel script: `scripts/db-tunnel.sh` (pass `redis` as 2nd arg)
- App-level usage will land in `services/api/` once it exists — config will read `REDIS_URL` constructed from `redis_primary_endpoint`, `redis_port`, and the AUTH token
