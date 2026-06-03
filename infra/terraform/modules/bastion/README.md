# Bastion module

A minimal EC2 instance used as an SSM Session Manager jump host into the staging VPC. Lets developers tunnel from their laptop to the private RDS (and later Redis) without exposing those services to the public internet.

**Staging only.** Production access goes through the API; there is no human-tunnel path to the prod database by design.

---

## What this is and isn't

| | |
|---|---|
| **Is** | A network hop. Forwards bytes between your laptop's SSM session and a private VPC resource. |
| **Is not** | A jump host you SSH into to "do work." There is no SSH, no shell access by default (though SSM exec is available — see below), no developer accounts. |
| **Is** | Reachable only via AWS IAM-authenticated SSM. |
| **Is not** | Reachable from the public internet at all. No public IP, no port 22, no inbound rules. |
| **Is** | One instance, in one AZ, in one private app subnet. |
| **Is not** | Multi-AZ or HA. If the AZ fails, you wait or re-apply into a different AZ. Acceptable — the bastion is a developer tool, not a production dependency. |

---

## Architecture

```
Your laptop                    AWS                          VPC (10.0.0.0/16)
─────────────                  ───────                       ──────────────────
                                                              private subnet
DBeaver/psql                                                  ┌──────────────┐
   │                          SSM control plane               │              │
   │   1. aws ssm              (ssm.ap-south-1)               │   Bastion    │
   │      start-session   ───→ "open a port-forward          │   t4g.nano   │
   │                            session to host=DB_HOST"  ──→│   (no IP)    │
   │                                                          │              │
   │   2. local TCP                                           │              │
   │      localhost:5432  ─────── tunneled via SSM ──────────→│ TCP 5432 ────┼──→ RDS (data subnet)
   │                                                          └──────────────┘
   │                                                              ↑
   │                                                              │  egress-only SG:
   │                                                              │   443 → 0.0.0.0/0 (NAT)
   │                                                              │   5432 → RDS SG
   └─→ session-manager-plugin (local binary) maintains the TCP tunnel through the SSM session
```

---

## Prerequisites (one-time per developer)

### 1. AWS CLI v2
```bash
brew install awscli
aws --version    # 2.x
```

### 2. SSM Session Manager plugin
```bash
brew install --cask session-manager-plugin
session-manager-plugin --version
```

The plugin is what actually runs the local TCP forwarder; the AWS CLI alone is not enough.

### 3. AWS credentials with the right IAM permissions

Whatever IAM identity you use needs:
- `ssm:StartSession` on the bastion instance ARN (or on `arn:aws:ec2:ap-south-1:*:instance/*`)
- `ssm:TerminateSession` on `arn:aws:ssm:*:*:session/${aws:username}-*` (only your own sessions)
- (For port forwarding) `ssm:StartSession` on the document `arn:aws:ssm:*::document/AWS-StartPortForwardingSessionToRemoteHost`

If you're using your root account or an admin role for early MVP work, you have all of this. The least-privilege IAM policy comes later.

### 4. psql (only needed for Step 3, not for the tunnel itself)
```bash
brew install libpq
brew link --force libpq
psql --version
```

---

## Day-to-day usage

### Open a tunnel to staging Postgres

Terminal 1 — leave this running:
```bash
./scripts/db-tunnel.sh
```

Defaults to `staging` env, local port `5432`. Output:
```
→ Tunneling localhost:5432 → medical-ai-staging.xxx.ap-south-1.rds.amazonaws.com:5432
  bastion: i-0abc123...
  (Ctrl+C to close)

Waiting for connections...
```

To pick a different local port (e.g. if you already have Postgres on 5432):
```bash
./scripts/db-tunnel.sh staging 15432
```

### Connect with psql

Terminal 2:
```bash
PGPASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id medical-ai/staging/rds/master \
  --query SecretString --output text | jq -r .password) \
psql --host=localhost --port=5432 \
  --username=vaidya_admin --dbname=medical_ai "sslmode=require"
```

### Connect with DBeaver

| Field | Value |
|---|---|
| Host | `localhost` |
| Port | `5432` (or whatever you passed to the script) |
| Database | `medical_ai` |
| Username | `vaidya_admin` |
| Password | from `aws secretsmanager get-secret-value` (see above) |
| SSL mode | `require` |

Save the connection. The password will change on rotation — re-fetch from Secrets Manager.

---

## Getting a shell on the bastion itself

You shouldn't normally need this, but for debugging the bastion (e.g. installing tools temporarily, checking SSM agent logs):

```bash
INSTANCE_ID=$(cd infra/terraform/envs/staging && terraform output -raw bastion_instance_id)

aws ssm start-session --target "$INSTANCE_ID"
```

You land in a shell as `ssm-user`. No `sudo` password is needed; the SSM agent runs as root. To exit: `exit`.

**Don't** install application code, secrets, or long-lived state on the bastion. Treat it as ephemeral — anything you put on it will be wiped when the instance is rebuilt.

---

## Security model

| Layer | Control |
|---|---|
| Network | No public IP. No inbound SG rules at all. Outbound limited to HTTPS (443) for SSM and TCP 5432 to the RDS SG. |
| Authentication | AWS IAM. There are no users, passwords, or SSH keys on the bastion. The SSM agent talks to AWS using the instance profile. |
| Authorization | Per-developer IAM permissions decide who can `ssm:StartSession`. Revoking access is an IAM policy change, not a key rotation. |
| Audit | Every `start-session` call is logged in CloudTrail with the caller's IAM identity, target instance, and session duration. PHI access via the tunnel is traceable to a specific person. |
| Instance metadata | IMDSv2 required (`http_tokens = "required"`). Blocks the SSRF-to-credential-exfil class of vulnerabilities. |

### Trust boundary

The bastion's IAM role has **only** `AmazonSSMManagedInstanceCore`. It cannot:
- Read Secrets Manager (so the bastion never sees DB credentials)
- Read S3 (so the bastion never sees uploaded reports)
- Call RDS APIs (so the bastion cannot modify the DB beyond what its SQL connection allows)

If the bastion is compromised, the blast radius is "an attacker can forward to RDS port 5432" — they still need DB credentials from Secrets Manager, which the bastion does not have.

### What audit logs to check

CloudTrail event names:
- `StartSession` — who opened a tunnel, when
- `TerminateSession` — when it closed
- `GetSecretValue` (on `medical-ai/staging/rds/master`) — who fetched the DB password

The `responseElements.sessionId` in `StartSession` cross-references with the developer's later DB queries in the Postgres slow-query log if needed.

---

## Cost

| Component | Approx. monthly cost |
|---|---|
| t4g.nano instance | $3.07 |
| 8 GB gp3 EBS | $0.64 |
| NAT data egress (bastion → SSM) | < $0.10 (sessions are small) |
| **Total** | **~$4/month** |

You can stop the instance when not in use (`aws ec2 stop-instances --instance-ids ...`); you only pay for the EBS volume (~$0.64) while it's stopped. Restart with `start-instances` before opening a tunnel.

---

## Lifecycle and patching

The bastion uses the **latest Amazon Linux 2023 ARM64 AMI** at apply time, sourced from a public SSM parameter (`/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-arm64`). The AMI ID is **not pinned**.

This means:
- Each fresh `terraform apply` may pick up a newer AMI → `aws_instance.bastion` will plan to replace the instance.
- We accept this. The bastion holds no state; replacement is safe.
- To force a rebuild on the current AMI (e.g. to pick up a security patch): `terraform apply -replace=module.bastion.aws_instance.bastion`.

Do **not** SSH-style update packages on the running instance — they'll be lost on rebuild. Anything you actually need should go in the Terraform config (e.g. a `user_data` script, which we don't have today).

---

## Troubleshooting

### `An error occurred (TargetNotConnected) when calling the StartSession operation`

The bastion's SSM agent isn't registered with AWS, or the instance is stopped.

Check:
```bash
aws ec2 describe-instances --instance-ids $(cd infra/terraform/envs/staging && terraform output -raw bastion_instance_id) \
  --query 'Reservations[0].Instances[0].State.Name'

aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$(cd infra/terraform/envs/staging && terraform output -raw bastion_instance_id)"
```

If `State.Name` is `stopped`: `aws ec2 start-instances --instance-ids ...`. Wait 2 min for the SSM agent to register.

If the instance is running but `describe-instance-information` returns empty: NAT may be down, or the SSM agent can't reach the SSM endpoints. Check the NAT gateway in the AWS console.

### `Unable to start session ... SessionManagerPlugin is not found`

The `session-manager-plugin` binary isn't installed or isn't on PATH.
```bash
brew install --cask session-manager-plugin
which session-manager-plugin
```

### Tunnel opens but `psql: could not connect to server: Connection refused`

The tunnel isn't actually forwarding. Likely causes:
1. The script crashed silently — check terminal 1 for errors.
2. You connected to the wrong local port — match it to the `localPortNumber` the script printed.
3. The bastion's egress SG rule to RDS is missing — `terraform plan` should be clean; if it shows drift, apply.

### `psql: FATAL: no pg_hba.conf entry ... no encryption`

You omitted `sslmode=require`. The RDS parameter group sets `rds.force_ssl = 1`. Add it.

### `psql: FATAL: password authentication failed for user "vaidya_admin"`

You typed the password wrong. Use the inline `PGPASSWORD=$(aws ...)` form to avoid copy-paste errors.

### Session idles out after a few minutes

SSM port-forwarding sessions disconnect after ~20 minutes of TCP inactivity. Re-run `./scripts/db-tunnel.sh`. For long migrations, run them via `psql -f file.sql` instead of an interactive shell — completed commands keep the connection live.

### Apply wants to replace the bastion instance and I didn't change anything

AL2023 AMI advanced upstream. The data source resolved to a new AMI ID. Safe to apply — the bastion is stateless. If you need to keep the existing instance for some reason: `terraform apply -target=` everything else and skip the bastion this round.

---

## Decommissioning

To remove the bastion permanently (e.g. once the team uses a Tailscale-based approach):

1. Remove `module "bastion"` from `envs/staging/main.tf`.
2. Remove the bastion outputs from `envs/staging/outputs.tf`.
3. `terraform apply` — destroys the instance, role, SG, and the RDS ingress rule that the bastion module owned.
4. Delete `scripts/db-tunnel.sh`.

The RDS SG itself remains untouched. The bastion's ingress rule on it was a separate resource owned by the bastion module, so it's cleaned up automatically.
