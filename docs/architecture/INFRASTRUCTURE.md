# Infrastructure design

The architecture, design decisions, trade-offs, and future scope for the Medical AI Sprint 1 infrastructure. Pair this doc with the per-module READMEs in `infra/terraform/modules/*/` for hands-on operational detail; this doc is the *why*.

---

## Table of contents

1. [Context — what shapes every decision](#1-context--what-shapes-every-decision)
2. [Architecture at a glance](#2-architecture-at-a-glance)
3. [Cross-cutting concerns](#3-cross-cutting-concerns)
   - 3.1 [Encryption strategy](#31-encryption-strategy)
   - 3.2 [Network topology](#32-network-topology)
   - 3.3 [Secrets management](#33-secrets-management)
   - 3.4 [Multi-environment strategy](#34-multi-environment-strategy)
   - 3.5 [State management](#35-state-management)
4. [Per-module deep dive](#4-per-module-deep-dive)
   - 4.1 [KMS](#41-kms)
   - 4.2 [VPC](#42-vpc)
   - 4.3 [Secrets](#43-secrets)
   - 4.4 [S3 (reports bucket)](#44-s3-reports-bucket)
   - 4.5 [SQS (job queues)](#45-sqs-job-queues)
   - 4.6 [RDS (Postgres + pgvector)](#46-rds-postgres--pgvector)
   - 4.7 [Bastion](#47-bastion)
   - 4.8 [Redis (ElastiCache)](#48-redis-elasticache)
5. [Cost model](#5-cost-model)
6. [What's not in Sprint 1](#6-whats-not-in-sprint-1)
7. [Future scope](#7-future-scope)

---

## 1. Context — what shapes every decision

### The product

A medical AI assistant that explains health reports and lab results to users in plain language. Built around one constraint:

> **It never diagnoses. It never prescribes. It never replaces a doctor.**

Everything that follows — from the encryption posture to the choice of compute platform — is downstream of this constraint and the regulatory environment in India.

### The regulatory environment

| Constraint | Source | Implication |
|---|---|---|
| Data residency | DPDP Act 2023 (India) | All PHI must remain in India — we use `ap-south-1` (Mumbai) exclusively, no cross-region replication |
| Encryption at rest | DPDP Act 2023 "reasonable security safeguards" | Customer-managed KMS keys for all PHI-bearing storage (RDS, S3 reports) |
| Encryption in transit | Same | TLS enforced at the server level (RDS `force_ssl=1`, Redis `transit_encryption_enabled`, S3 bucket policy denies non-TLS) |
| Audit logging | Same + healthcare best practice | CloudTrail on; audit log table append-only (planned for Sprint 2) |
| Data minimization | DPDP Act 2023 | PII tokenization wraps every external AI/OCR call (planned for Sprint 2) |

### The non-negotiables (from `CLAUDE.md`)

These are encoded directly in the infrastructure design — not as policy documents to remember but as resource configuration that *cannot* be wrong:

1. **PII tokenization wraps every call to Claude, Textract, and Cohere.** (App-level — not yet built.)
2. **No PHI in Redis.** → Drove the Redis design: no PHI-related caching even when tempting.
3. **No PHI in logs.** → Log group encryption with our CMK; structured fields not free-form report text.
4. **Audit log is append-only.** → Future RDS RLS policy + revoked UPDATE/DELETE grants.
5. **S3 objects are never public.** → Block Public Access (all 4 flags), bucket policy denies non-TLS, only KMS-encrypted writes accepted.
6. **Emergency template bypasses Claude.** (App-level — not yet built.)
7. **RLS on all user tables.** (Per-migration — not yet built.)
8. **All resources in `ap-south-1`.** → AWS provider hardcoded to this region in every env's `versions.tf`. No multi-region patterns anywhere.

---

## 2. Architecture at a glance

```
                                                                            
                              Internet                                     
                                  │                                        
                                  ▼                                        
                        ┌───────────────────┐                              
                        │  CloudFront       │   (Sprint 2)                 
                        │  + WAF            │                              
                        └─────────┬─────────┘                              
                                  │                                        
                                  ▼                                        
        ┌──────────────────────────────────────────────────────────┐       
        │                    VPC (10.0.0.0/16)                     │       
        │                                                          │       
        │   ┌──────── public subnets (× 2 AZ) ─────────┐           │       
        │   │  NAT gateway   ALB (Sprint 2)            │           │       
        │   └──────────────────────────────────────────┘           │       
        │                                                          │       
        │   ┌──────── private app subnets (× 2 AZ) ────┐           │       
        │   │  Fargate API    Lambda worker            │           │       
        │   │  (Sprint 2)     (Sprint 2)               │           │       
        │   │  Bastion (staging only)                  │           │       
        │   └──────────────────────────────────────────┘           │       
        │                                                          │       
        │   ┌──────── data subnets (× 2 AZ) ───────────┐           │       
        │   │  RDS Postgres 16    ElastiCache Redis 7  │           │       
        │   │  (with pgvector)                         │           │       
        │   └──────────────────────────────────────────┘           │       
        │                                                          │       
        │   ┌──────── VPC endpoints (interface + gateway) ─┐       │       
        │   │  S3 (gateway)                                │       │       
        │   │  SQS, Secrets Manager, Textract, ECR, Logs   │       │       
        │   └──────────────────────────────────────────────┘       │       
        └──────────────────────────────────────────────────────────┘       
                                                                            
   ┌─────────────────────────── AWS services (regional) ─────────────────┐ 
   │  S3 reports bucket       SQS ocr-jobs + extraction-jobs (+ DLQs)    │ 
   │  Secrets Manager (5)     KMS (app-data key + reports key)           │ 
   └─────────────────────────────────────────────────────────────────────┘ 
```

### Module dependency graph

```
                   kms ──────────────────────────────┐
                    │                                │
                    ├──► secrets ────────────────────┤
                    │      │                         │
                    │      └──► rds ────► bastion ◄──┤
                    │      │                         │
                    │      └──► redis ────────────►  │
                    │                                │
                    └──► s3 ◄────────────────────────┘
                    └──► sqs ◄──── s3 (event notification)
                   vpc ──────────► rds, redis, bastion
```

What's notable:
- KMS is the foundation — everything that holds data depends on it
- VPC is the network foundation — everything network-bound depends on it
- Secrets feeds RDS and Redis credentials
- S3 ↔ SQS is the only intentional cross-resource event coupling
- Bastion sits on top of RDS + Redis to provide access during development

---

## 3. Cross-cutting concerns

### 3.1 Encryption strategy

**Two customer-managed KMS keys, separated by data sensitivity:**

| Key | Used by | Why separate |
|---|---|---|
| `app_key` | RDS storage + Redis at-rest + Secrets Manager + SQS messages + CloudWatch Logs (Sprint 2) | Operational data — sessions, queue messages, app state |
| `reports_key` | S3 reports bucket — the user-uploaded medical PDFs | The highest-sensitivity data. Separated so compromise of one key doesn't expose both. Also makes audit trails clearer in CloudTrail. |

**Why customer-managed keys (CMKs), not AWS-managed:**
- Revocability — we can disable the key to immediately make all encrypted data unreadable, even by AWS itself
- Auditability — every KMS API call (encrypt, decrypt, generate-data-key) shows up in CloudTrail with the principal and the resource
- Compliance — DPDP Act expectations around "reasonable security safeguards" are easier to demonstrate with explicit key ownership

**Rotation:**
- Both keys have `enable_key_rotation = true` — AWS rotates the underlying key material annually
- Old key versions remain available indefinitely, so old encrypted data still decrypts
- The KMS key ARN is stable across rotations — no resource changes needed elsewhere

**Pros:** Strong compliance posture, explicit revocability, clean audit boundaries.
**Cons:** ~$1/month per key ($24/year total for two keys × two envs). Negligible.
**Trade-offs we accepted:** Bastion's OS volume uses the AWS-managed EBS key (free, no PHI on the volume). Worth $0 in saved cost; negligible audit impact.

### 3.2 Network topology

**A three-tier subnet model across two AZs:**

| Tier | Public IPs | Internet route | Contents |
|---|---|---|---|
| `public` | Yes | Direct via IGW | NAT gateway, future ALB |
| `private` | No | Outbound via NAT only | Future Fargate API, Lambda worker, bastion |
| `data` | No | None | RDS, Redis |

**Why three tiers, not two:**
- A two-tier model (public + private) means data services share a subnet with compute. A misconfigured compute SG can then accidentally expose the database.
- With a separate `data` tier that has no internet route at all, even a fully misconfigured RDS security group (e.g. `0.0.0.0/0` ingress — never set, but hypothetically) cannot be reached from the public internet. The subnet's route table doesn't have a default route.
- This is **defense in depth** — the SGs are the primary control; the route tables are the secondary control.

**Single NAT gateway, not one per AZ:**
- A NAT gateway costs ~$32/month + $0.045 per GB processed
- Two NAT gateways (one per AZ for HA) would be ~$64/month
- For MVP scale we accept the trade-off: if AZ-A goes down, compute in AZ-B loses internet egress (Claude, Cohere API calls fail). This is recoverable in minutes by recreating NAT in AZ-B.
- Worth revisiting once we have real traffic — Sprint 3 or post-launch.

**VPC endpoints (interface + gateway):**

| Service | Type | Purpose |
|---|---|---|
| S3 | Gateway | Cheap (~free). Private route to S3 for the upload flow. |
| SQS | Interface | Workers don't need NAT to reach SQS |
| Secrets Manager | Interface | API doesn't need NAT to fetch credentials |
| Textract | Interface | OCR worker doesn't need NAT to call Textract |
| ECR | Interface | Fargate doesn't need NAT to pull container images |
| CloudWatch Logs | Interface | Logging from private subnets doesn't traverse NAT |

**Why we have endpoints for these specific services:** they're the AWS services our app talks to most frequently. Without endpoints, every API call would go through NAT, adding cost ($0.045/GB) and a single point of failure.

**Why no `ssm`/`ssmmessages`/`ec2messages` endpoints (yet):** The bastion is the only SSM consumer and it lives in the private (NAT-routed) subnet. Adding three more interface endpoints would cost ~$22/month — not worth it until we have many SSM consumers (e.g. ECS tasks managed via SSM exec).

**Pros:** Defense-in-depth network model, cost-efficient endpoint selection, clean separation of compute and data.
**Cons:** Single-NAT is a known availability gap. Cross-AZ traffic for the standby Redis/RDS adds cost.
**Future:** Second NAT, SSM endpoints, possible Transit Gateway if we ever need to peer with another VPC.

### 3.3 Secrets management

**Hierarchical naming:**

```
medical-ai/{env}/{component}/{purpose}
└─ medical-ai/staging/rds/master
└─ medical-ai/staging/redis/auth-token
└─ medical-ai/staging/claude/api-key
└─ medical-ai/staging/cohere/api-key
└─ medical-ai/staging/supabase/jwt-secret
```

**Two creation patterns:**

| Pattern | Used for | How it works |
|---|---|---|
| TF-generated | `rds/master`, `redis/auth-token` | `random_password` resource generates the value; `aws_secretsmanager_secret_version` writes it into the secret at apply time |
| TF container + human fill | `claude/api-key`, `cohere/api-key`, `supabase/jwt-secret` | Terraform creates only the empty secret. The value is pasted by an operator via `aws secretsmanager put-secret-value`. **No `_version` resource exists for these in Terraform.** |

**Why the split:**
- TF-generated values are owned by Terraform end-to-end. Apply creates a strong password; the value is in state (encrypted, but present); rotation is a deliberate two-step process.
- Externally-issued credentials (Anthropic, Cohere, Supabase) **must not** be in Terraform state. They're issued by third parties; rotation happens on their dashboard, not ours. If Terraform owned them, every apply would either overwrite them with garbage or get out of sync with state.

**Why `lifecycle.ignore_changes = [password|auth_token]` on RDS and Redis:**
- Rotation is intentional, not a side effect of `terraform apply`
- Without this, a `put-secret-value` in Secrets Manager would not affect Terraform state, but the next apply would re-set the DB password to what's in TF state — i.e., overwrite the rotation

**Recovery window: 30 days (prod), 7 days (staging):**
- AWS doesn't immediately delete secrets — they enter a recovery window. During that window the secret can be restored.
- 30 days for prod gives runway to recover from "oops, that wasn't the staging account"
- 7 days for staging lets us iterate faster without hitting "secret with this name is pending deletion"

**Pros:** Clean ownership boundaries, strong rotation discipline, no third-party credentials in state.
**Cons:** Operator must manually populate three secrets after first apply (documented in `INFRA_BOOTSTRAP.md`). Rotation flows are manual.
**Future:** Secrets Manager native rotation Lambdas for RDS and Redis (built-in templates exist). Worth doing in Sprint 3 once we have a rotation cadence.

### 3.4 Multi-environment strategy

**Per-env root modules, not workspaces:**

```
infra/terraform/envs/
├── staging/
│   ├── backend.tf      # state key: staging/terraform.tfstate
│   ├── main.tf
│   ├── outputs.tf
│   ├── variables.tf
│   └── versions.tf
└── prod/
    ├── backend.tf      # state key: prod/terraform.tfstate
    ├── main.tf
    ├── outputs.tf
    ├── variables.tf
    └── versions.tf
```

**Why not Terraform workspaces:**
- Workspaces share one state file with workspace-keyed sub-trees. A `terraform apply` in the wrong workspace can scribble on the wrong env.
- Workspaces don't isolate provider configuration. We want each env to feel like a separate Terraform project, with no global flags that could be set wrong.
- The CLAUDE.md commands `cd infra/terraform/envs/staging && terraform apply` are explicit and hard to mistake.

**Why per-env settings live in `envs/*/main.tf` not `*.tfvars`:**
- We don't use `-var-file` flags — the env directory itself *is* the variable scope
- All env-specific settings (instance sizes, retention periods, deletion protection) are visible in one file per env
- Diffing `envs/staging/main.tf` against `envs/prod/main.tf` shows exactly what differs

**Pros:** Maximum isolation, no risk of cross-env mistakes, env-specific settings are visible together.
**Cons:** Two copies of every `module "x"` block — module signatures must change in both. Mitigated by small module count and clear conventions.
**Future:** If we add more environments (e.g. `dev`, `prod-canary`), this gets repetitive. Worth revisiting at 3+ envs.

### 3.5 State management

**S3 + DynamoDB backend, one state object per env:**

```
s3://medical-ai-terraform-state-<account-id>/
├── staging/terraform.tfstate
└── prod/terraform.tfstate

DynamoDB: medical-ai-terraform-locks  (LockID = state path)
```

- **S3 versioning enabled** — recover from accidental state corruption
- **S3 server-side encryption** with AWS-managed AES256 (bootstrapped before KMS exists; could be upgraded to CMK post-bootstrap)
- **DynamoDB lock table is pay-per-request** — handful of writes per apply, $0 effectively
- **State contains secrets** (the rds/master JSON, the redis/auth-token string) — never share state files, never commit, restrict S3 bucket IAM

**The chicken-and-egg in bootstrap:**
- Terraform state needs S3 + DynamoDB before any module can run
- These must be created **outside** Terraform — the bootstrap doc shows the raw `aws` CLI commands
- Could we create them with a second Terraform project that uses local state? Yes, but that just moves the problem and adds complexity. The CLI commands are clearer.

**Pros:** Locking prevents concurrent applies, versioning enables recovery, encryption protects secrets in state.
**Cons:** State has secrets. Mitigated by strict IAM, but worth restating.
**Future:** Move state encryption from AES256 to our CMK once KMS exists. Add S3 access logging on the state bucket for audit.

---

## 4. Per-module deep dive

### 4.1 KMS

**Purpose:** Encryption keys for every other module that holds data.

**What it provisions:**
- `app_key` — used by RDS storage, Redis at-rest, Secrets Manager, SQS, CloudWatch (Sprint 2)
- `reports_key` — used only by the S3 reports bucket
- Aliases (`alias/medical-ai-app-{env}`, `alias/medical-ai-reports-{env}`) for human readability

**Design decisions:**
- **Two keys, not one:** isolation of blast radius. Compromise of one doesn't expose data encrypted with the other.
- **Annual rotation enabled** on both — AWS handles material rotation; we don't change anything.
- **30-day deletion window** — KMS doesn't allow immediate deletion. The window is the recovery period during which a `cancel-key-deletion` will save you.
- **Default key policy** — the account's IAM users can manage the key. Future improvement: lock this down to specific IAM roles only.

**Pros:** Strong compliance, simple to reason about, near-zero operational burden.
**Cons:** ~$2/month per env (two keys × $1). The cost of doing it right.
**Future:** Tighten key policies once we have least-privilege IAM roles. Add key grants for specific Lambda execution roles in Sprint 2.

### 4.2 VPC

**Purpose:** The private network everything else runs in.

**What it provisions:**
- 1 VPC (`10.0.0.0/16`), 2 AZs
- 6 subnets total: 2 public (`10.0.1.0/24`, `10.0.2.0/24`), 2 private (`10.0.11.0/24`, `10.0.12.0/24`), 2 data (`10.0.21.0/24`, `10.0.22.0/24`)
- 1 NAT gateway in the first public subnet
- 3 route tables (public, private, data)
- 6 VPC endpoints (S3 gateway; SQS, Secrets Manager, Textract, ECR, CloudWatch Logs as interfaces)
- 2 subnet groups (RDS, ElastiCache) — both reference the data subnets
- Security groups (edge_sg, data_sg) — currently empty placeholders for Sprint 2

**Design decisions:**
- **`enable_dns_hostnames = true`** — required for interface VPC endpoints to resolve to private IPs
- **Single NAT gateway** — cost optimization (~$32/mo instead of $64/mo); explicit availability trade-off
- **No private DNS for interface endpoints set explicitly** — defaults are fine; AWS handles the Route53 zone
- **`/24` per subnet** — gives us 251 usable IPs per subnet. Plenty for the planned workload; reserves room for the VPC to grow vertically without renumbering.

**Pros:** Clean three-tier model, defense-in-depth via route table isolation, endpoint coverage minimizes NAT traffic.
**Cons:** Single NAT is an availability gap. Six VPC endpoints aren't free (~$30/month per env).
**Future:** Second NAT gateway in AZ-B. SSM endpoints when we have many SSM consumers. CloudWatch Logs Insights endpoints if log query volume grows.

### 4.3 Secrets

**Purpose:** Centralized credential storage with KMS encryption.

**What it provisions:**
- 5 secret containers (rds/master, redis/auth-token, claude/api-key, cohere/api-key, supabase/jwt-secret)
- 2 versions (only the TF-owned ones — rds master and redis auth)
- `random_password` resources generating the TF-owned values

**Design decisions:**
- **Hierarchical naming** — `medical-ai/{env}/{component}/{purpose}` — extensible without conflicts
- **Generated passwords with charset restrictions** — RDS password excludes `/`, `"`, `@` because the Postgres connection URL can't quote them cleanly. Redis token uses a narrower charset because ElastiCache validates the AUTH token format strictly.
- **`recovery_window_in_days` differs per env** — 7 staging, 30 prod. Faster iteration in staging, longer safety net in prod.
- **No `_version` resource for human-managed secrets** — Terraform creates the container, an operator fills it. Documented in `INFRA_BOOTSTRAP.md` Phase 2.

**Pros:** Clean ownership model, no third-party credentials in state, strong rotation discipline.
**Cons:** Manual step required after first apply. Worth automating in CI eventually.
**Future:** Automated rotation Lambdas for the TF-owned secrets. Vault integration if we ever outgrow Secrets Manager (unlikely at this scale).

### 4.4 S3 (reports bucket)

**Purpose:** Storage for user-uploaded medical reports (PDFs, images).

**What it provisions:**
- 1 bucket (`medical-ai-reports-{env}-{account-id}`) with the account ID for global uniqueness
- Public Access Block (all 4 flags `true`)
- SSE-KMS with `reports_key`, `bucket_key_enabled = true`
- Versioning enabled
- Lifecycle rules (7-day abort-multipart-upload, 30-day expire-noncurrent-versions)
- CORS rule for browser PUT/POST (pre-signed URL flow)
- Bucket policy with three deny statements (insecure transport, unencrypted PUT, wrong KMS key)
- Bucket notification → SQS ocr-jobs queue, filtered on `uploads/` prefix, all ObjectCreated events

**Design decisions:**
- **Bucket name includes account ID** — Terraform doesn't manage bucket-name uniqueness; baking the account ID in eliminates collisions on rebuild
- **`bucket_key_enabled = true`** — caches a per-bucket data key, reducing KMS API costs by ~99% for high-write workloads. No security impact.
- **CORS limited to PUT/POST** — pre-signed URLs work for GETs without CORS; a wildcard GET CORS rule would advertise the bucket as cross-origin-readable, which is wrong for PHI
- **VPCE restriction in bucket policy is deferred** — it conflicts with the pre-signed URL upload flow (browser uploads come from the user's IP, not the VPC). Worth revisiting once the upload path is in production.
- **Bucket notification lives in the S3 module**, even though it depends on SQS. Reason: AWS treats the notification as a property of the bucket. We resolve the circular dependency (S3 needs SQS queue ARN, SQS needs bucket ARN) by constructing the bucket ARN as a string literal in the env file.

**Pros:** Strong encryption + access controls, lifecycle protects against runaway costs, event-driven OCR pipeline is fully declarative.
**Cons:** VPCE restriction deferred. Lifecycle for noncurrent-version-expiry (30 days) is conservative for PHI — a privacy-conscious deployment might use 7 days.
**Future:** S3 server access logging (operations sprint). Replication to a separate retention bucket for compliance. Object Lock if we ever need WORM guarantees.

### 4.5 SQS (job queues)

**Purpose:** Buffer between S3 uploads and the Lambda OCR worker (and a second queue for extraction).

**What it provisions:**
- 4 queues: `ocr-jobs`, `ocr-jobs-dlq`, `extraction-jobs`, `extraction-jobs-dlq`
- KMS encryption with `app_key` on all 4
- Long polling (`receive_wait_time_seconds = 20`) to reduce empty-receive costs
- Redrive policy with `maxReceiveCount = 5` from main queues to DLQs
- Visibility timeouts sized for processing: OCR 120s, extraction 60s
- Queue policy on `ocr-jobs` allowing S3 SendMessage from the reports bucket

**Design decisions:**
- **Standard queues, not FIFO** — order doesn't matter (reports are independent), and FIFO has lower throughput limits
- **DLQs are full SQS queues, not just configuration** — separate queue ARN, separate KMS encryption, separate visibility settings
- **`maxReceiveCount = 5`** — five attempts before going to DLQ. Three is too aggressive (transient errors stalling the pipeline); ten is too lenient (genuinely-broken messages keep retrying for hours).
- **Two separate queues (OCR + extraction), not one** — different processing characteristics (OCR is Textract-bound, extraction is Claude-bound), different visibility timeouts, independent scaling later.
- **Visibility timeout ≥ 6× expected processing time** — Lambda timeout sits inside this window; SQS retries only happen after the message is back to visible.

**Pros:** Decoupled producer and consumer, retry semantics built-in, DLQ for offline analysis, KMS-encrypted message bodies.
**Cons:** Two separate queues means twice the cardinality in monitoring. Acceptable.
**Future:** CloudWatch alarms on DLQ depth (any message in a DLQ should page someone). Possibly FIFO for the extraction queue if we discover ordering requirements (unlikely).

### 4.6 RDS (Postgres + pgvector)

**Purpose:** Primary application data store. Holds users, reports, biomarker values, RAG knowledge base, embeddings.

**What it provisions:**
- 1 `aws_db_instance` (`medical-ai-{env}`)
- 1 parameter group (`medical-ai-{env}-pg16`)
- 1 security group with empty ingress (compute adds rules later)

**Design decisions:**
- **Postgres 16, not Aurora** — RDS for Postgres is the simplest option; pgvector ships with it; Aurora's faster failover and storage-layer features aren't needed at MVP scale. Saves significant cost.
- **pgvector preloaded via parameter group**, not installed at the AMI level — `shared_preload_libraries = "pg_stat_statements,vector"`. Requires reboot, which RDS does automatically on creation.
- **TLS enforced via `rds.force_ssl = 1`** — server-level rejection of non-TLS connections. Defense in depth on top of the network SG.
- **`log_statement = ddl`, not `all`** — `all` would log every SELECT including PHI in WHERE clauses. `ddl` captures schema changes for audit without leaking values.
- **Master credentials read from existing Secrets Manager secret** — Pattern A from the concepts doc. The password lives in TF state but only briefly. Alternative (`manage_master_user_password = true`) creates an RDS-owned secret with a separate name, doubling the credential surface.
- **`lifecycle.ignore_changes = [password]`** — rotation is deliberate, not a `terraform apply` side effect.
- **`final_snapshot_identifier` is conditional** on `skip_final_snapshot`. Prod gets a timestamped snapshot on destroy; staging skips it.
- **`auto_minor_version_upgrade = true`** — accept that AWS will apply 16.x patches in the maintenance window. Major versions stay manual.

**Pros:** Battle-tested Postgres, pgvector at the database layer (no separate vector DB), strong encryption posture, sane backup defaults.
**Cons:** Single-instance failover is ~60–120s of downtime. Multi-AZ doubles cost. Master password lives in TF state (mitigated by encrypted-at-rest state and restrictive IAM).
**Future:** Performance Insights once we have real query patterns. Read replicas if read load grows. Eventually Aurora if we hit storage-layer limits (unlikely for MVP).

### 4.7 Bastion

**Purpose:** Developer access path to private VPC resources (RDS, Redis) without exposing those resources to the internet.

**What it provisions:**
- 1 t4g.nano EC2 instance in a private app subnet
- IAM role + `AmazonSSMManagedInstanceCore` policy + instance profile
- Security group with no ingress, egress to SSM (443) and the RDS + Redis SGs
- 4 SG rules: bastion → RDS (egress + ingress on RDS SG), bastion → Redis (egress + ingress on Redis SG)

**Design decisions:**
- **SSM Session Manager, not SSH** — no SSH key management, no exposed port 22, IAM-based auth with CloudTrail audit trail
- **Latest AL2023 ARM64 AMI via SSM parameter** — AMI ID is not pinned; each apply may pick up a newer image, replacing the instance. Bastion is stateless; replacement is safe.
- **t4g.nano** — smallest ARM Graviton instance. ~$3/month. Forwarding TCP doesn't need compute.
- **IMDSv2 required** — blocks the SSRF-to-credential-exfil class of vulnerabilities
- **Bastion in private subnet (NAT-routed), not data subnet** — needs outbound HTTPS to reach SSM endpoints. The VPC module doesn't have SSM interface endpoints (cost optimization), so NAT egress is the path.
- **Staging only** — prod has no bastion. Prod DB access is via the app or short-lived operations like rotation, not human SSH-style work.

**Pros:** No SSH attack surface, IAM-integrated auth, audit trail per session, cheap.
**Cons:** Single-AZ. AL2023 AMI updates trigger replacement. NAT egress for SSM traffic.
**Future:** SSM interface endpoints once we have more SSM consumers (Sprint 2 ECS tasks). Tailscale if multiple developers need access. EC2 Instance Connect Endpoint as an alternative.

### 4.8 Redis (ElastiCache)

**Purpose:** Session storage, rate limit counters, idempotency keys, worker locks. **NO PHI.**

**What it provisions:**
- 1 `aws_elasticache_replication_group` (1 node in staging, 2 in prod)
- 1 parameter group (`maxmemory-policy = allkeys-lru`)
- 1 security group with empty ingress

**Design decisions:**
- **Cluster mode disabled** (replication group, not Redis Cluster) — working set is small, sharding adds complexity
- **`maxmemory-policy = allkeys-lru`** — default is `noeviction` which refuses writes on memory pressure. For a cache, evict LRU keys instead.
- **Encryption at rest with our CMK, in transit via TLS, AUTH token required** — all three on. Forces every client to be TLS-aware.
- **AUTH token sourced from Secrets Manager** — same pattern as RDS master. `lifecycle.ignore_changes = [auth_token]`.
- **Snapshot retention = 1 day** — cache is recoverable from app logic; the snapshot is for rollback from accidental FLUSHDB, not compliance
- **Staging is 1 node, prod is 2 + failover + multi-AZ** — staging cache loss is recoverable from app; prod uptime matters more
- **Bastion SG attaches to Redis SG** — same pattern as RDS, supports debugging in staging

**Pros:** Standard managed Redis, encryption posture matches RDS, AUTH-protected, evicting cache when full.
**Cons:** Can't be stopped (unlike RDS); 24/7 cost. Transit encryption forces TLS-aware clients (modest constraint).
**Future:** Redis 6 ACLs if we want per-application credentials. Cluster mode if working set grows beyond a few GB. Reserved instances for prod (~30% savings) once usage is steady.

---

## 5. Cost model

### Monthly cost — staging

| Resource | Cost |
|---|---|
| VPC (NAT gateway + EIP) | $34 |
| Interface VPC endpoints (× 5) | $36 |
| KMS keys (× 2) | $2 |
| RDS db.t4g.micro (single-AZ, 20 GB gp3) | $14 |
| ElastiCache cache.t4g.micro | $13 |
| Bastion t4g.nano + EBS | $4 |
| S3 (low usage) | < $1 |
| SQS (low usage) | < $1 |
| Secrets Manager (5 secrets) | $2 |
| CloudWatch (minimal) | < $1 |
| **Total** | **~$107/month** |

### Monthly cost — prod (steady state, low traffic)

| Resource | Cost |
|---|---|
| VPC (NAT gateway + EIP) | $34 |
| Interface VPC endpoints (× 5) | $36 |
| KMS keys (× 2) | $2 |
| RDS db.t4g.small (multi-AZ, 50 GB gp3) | $55 |
| ElastiCache (2× cache.t4g.small, multi-AZ) | $54 |
| S3 (low usage) | < $1 |
| SQS (low usage) | < $1 |
| Secrets Manager (5 secrets) | $2 |
| CloudWatch (minimal) | $5 |
| **Total** | **~$189/month** |

### Cost drivers to watch as you scale

- **NAT egress** — at $0.045/GB, this becomes the largest variable cost item if Claude/Cohere traffic grows. Mitigation: aggressive caching, no unnecessary egress.
- **RDS storage** — gp3 grows automatically up to `max_allocated_storage`. Set the ceiling correctly to prevent runaway bills.
- **CloudWatch Logs ingestion** — at $0.50/GB. If we log verbosely, this dominates. Use log levels carefully and stream selectively.
- **Interface endpoints** — flat ~$7.20/month each. Six endpoints × two envs = $86/month just for VPC endpoints. Worth pruning unused endpoints.

### Cost optimizations not yet applied

- Reserved Instances / Savings Plans for RDS and ElastiCache (~30% savings) — wait until steady-state usage
- Single NAT for staging only — not yet implemented since the current setup is single-NAT everywhere

---

## 6. What's not in Sprint 1

The infrastructure complete in Sprint 1 is the **data plane** — storage, secrets, network, queues, encryption. Conspicuously missing:

| Missing piece | Sprint | What it'll be |
|---|---|---|
| Compute | 2 | ECS Fargate (API behind ALB for SSE), Lambda (SQS-triggered ingestion worker) |
| Application Load Balancer | 2 | ALB in public subnets, terminates TLS, routes to Fargate |
| CloudFront + WAF | 3 | Edge cache, DDoS protection, rate limits at the edge |
| Observability | 3 | CloudWatch dashboards, alarms, X-Ray tracing, structured app logs |
| Backups beyond RDS | 3 | AWS Backup with cross-region copies (when allowed by data residency) |
| CI/CD | 2 | GitHub Actions → ECR → ECS deployment |
| Container registry | 2 | ECR repositories (one per service) |
| Domain + TLS | 2/3 | Route53, ACM certificates |

The Sprint 1 infra is **complete enough to deploy compute on top**, which is exactly the boundary intended.

---

## 7. Future scope

### Near-term (Sprint 2–3)

- **Compute layer** — Fargate API + Lambda worker (Sprint 2's whole focus)
- **CloudWatch alarms** — DLQ depth, RDS connection count, Redis memory usage, NAT bytes processed, KMS key usage
- **Second NAT gateway** — close the AZ-A availability gap
- **SSM VPC endpoints** — once we have ECS tasks accessed via SSM exec, the ~$22/month becomes worth it
- **Cross-account state bucket replication** — disaster recovery for state itself

### Medium-term (post-MVP launch)

- **Performance Insights** on RDS — once we have real query patterns to tune against
- **RDS read replicas** — when read load justifies the cost
- **Reserved Instances / Savings Plans** — once usage is steady (3–6 months post-launch)
- **AWS Config + Security Hub** — automated compliance posture monitoring
- **AWS Backup** — for unified backup management across RDS, S3, EBS
- **VPC Flow Logs** — destination CloudWatch Logs or S3 for security analysis
- **GuardDuty** — threat detection across the account

### Long-term (1+ years post-launch)

- **Multi-region active-passive** — when the platform crosses the threshold where regional outage is unacceptable. India's DPDP Act would constrain options.
- **Aurora migration** — if RDS storage limits or failover speed become bottlenecks
- **Service mesh (App Mesh)** — only if microservice count grows past a manageable level
- **EKS migration** — only if we outgrow Fargate's operational simplicity. Don't migrate early; Fargate is excellent for our scale.
- **Hardware security module (CloudHSM)** — if we ever need FIPS 140-2 Level 3, more typical of payments than healthcare in India

### Operational improvements to revisit anytime

- **Automated secret rotation** for RDS master and Redis auth via Secrets Manager rotation Lambdas
- **VPCE restriction** on the S3 bucket policy once the upload path is in production
- **S3 server access logging** for auditability
- **Stricter IAM** on KMS keys (key policies that name specific roles, not the broad account-default policy)
- **Tighter security groups** — currently the data-tier SGs in the VPC module are placeholders; they'll need real ingress rules from compute

### Things explicitly off the roadmap

- **Multi-cloud** — unnecessary complexity for the scale; AWS coverage in `ap-south-1` is sufficient
- **On-premises hybrid** — no rationale for it
- **Public S3 buckets** — see CLAUDE.md hard rule #5. Never.
- **Cross-region PHI replication** — see CLAUDE.md hard rule #8. Never.

---

## See also

- `infra/terraform/modules/rds/README.md` — RDS post-apply runbook
- `infra/terraform/modules/bastion/README.md` — Bastion usage and security model
- `infra/terraform/modules/redis/README.md` — Redis usage and AUTH rotation
- `docs/operations/INFRA_BOOTSTRAP.md` — End-to-end bootstrap from a fresh AWS account
- `docs/architecture/SECURITY.md` — Application-level security (PII tokenization, audit log, RLS)
- `docs/architecture/DATA_MODEL.md` — Database schema and RLS policies (planned)
- `CLAUDE.md` — Project root document, non-negotiable rules
