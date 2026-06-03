# Infrastructure bootstrap — from a fresh AWS account

Step-by-step instructions for setting up the entire Medical AI infrastructure from scratch. Read end-to-end before starting; some steps are not reversible without manual cleanup.

**Estimated total time:** 60–90 minutes per environment (most of it is waiting on AWS).

---

## Table of contents

1. [Prerequisites](#1-prerequisites)
2. [Phase 0 — State backend bootstrap](#phase-0--state-backend-bootstrap)
3. [Phase 1 — Apply staging](#phase-1--apply-staging)
4. [Phase 2 — Populate manual secrets](#phase-2--populate-manual-secrets)
5. [Phase 3 — Post-RDS database setup](#phase-3--post-rds-database-setup)
6. [Phase 4 — Verify end-to-end](#phase-4--verify-end-to-end)
7. [Phase 5 — Apply prod](#phase-5--apply-prod)
8. [Common bootstrap issues](#common-bootstrap-issues)

---

## 1. Prerequisites

### AWS account

You need:
- An AWS account with billing enabled
- An IAM user (or SSO role) with admin permissions for the bootstrap, narrowed later
- The AWS Account ID (12 digits) — written down somewhere you can reference. Used in S3 bucket names.

### Local tooling

| Tool | Why | Install |
|---|---|---|
| Terraform ≥ 1.5 | IaC engine | `brew install terraform` |
| AWS CLI v2 | Authentication, post-apply verification | `brew install awscli` |
| SSM Session Manager plugin | Bastion tunnels | `brew install --cask session-manager-plugin` |
| jq | Parsing JSON secrets | `brew install jq` |
| psql (libpq) | Postgres client | `brew install libpq && brew link --force libpq` |
| redis-cli | Redis client (TLS-capable build) | `brew install redis` |

Verify all are on PATH:
```bash
terraform version
aws --version
session-manager-plugin --version
jq --version
psql --version
redis-cli --version
```

### AWS credentials

Configure a profile (or use the default). The credentials need permissions for: S3, DynamoDB, KMS, IAM, EC2 (VPC), RDS, ElastiCache, SQS, Secrets Manager, SSM.

```bash
aws configure
# AWS Access Key ID:     <your key>
# AWS Secret Access Key: <your secret>
# Default region name:   ap-south-1
# Default output format: json
```

Verify:
```bash
aws sts get-caller-identity
# Should print Account, UserId, Arn
```

If you use SSO:
```bash
aws sso login
aws sts get-caller-identity
```

---

## Phase 0 — State backend bootstrap

Terraform state needs a place to live before Terraform itself can run. This is a one-time per-AWS-account step (the same bucket is reused across all environments).

### 0.1 Create the S3 state bucket

The current configuration in `infra/terraform/envs/*/backend.tf` points at a specific bucket. Open one of them to see the name pattern:

```bash
cat infra/terraform/envs/staging/backend.tf
```

The bucket name is `medical-ai-terraform-state-<account-id>`. **You need to either**:
- **Option A** (recommended for forks/new accounts): change the bucket name in both `backend.tf` files to use your account ID, then create the bucket below.
- **Option B**: if you're working on the original account (`557231332919`), the bucket already exists — skip to Phase 1.

Assuming Option A — replace `<your-account-id>` below:

```bash
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="medical-ai-terraform-state-${ACCOUNT_ID}"

# Create the bucket
aws s3api create-bucket \
  --bucket "$BUCKET" \
  --region ap-south-1 \
  --create-bucket-configuration LocationConstraint=ap-south-1

# Block all public access — Terraform state contains secrets
aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# Enable versioning — recover from accidental state corruption
aws s3api put-bucket-versioning \
  --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

# SSE with AWS-managed key — we don't have our CMK yet (KMS module hasn't run)
aws s3api put-bucket-encryption \
  --bucket "$BUCKET" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      }
    }]
  }'
```

### 0.2 Create the DynamoDB lock table

Terraform uses a DynamoDB table to prevent two concurrent `apply` runs from colliding.

```bash
aws dynamodb create-table \
  --table-name medical-ai-terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region ap-south-1

# Wait for it to become ACTIVE (~30 seconds)
aws dynamodb wait table-exists \
  --table-name medical-ai-terraform-locks \
  --region ap-south-1
```

### 0.3 Update backend.tf if you changed the bucket name

Both files: `infra/terraform/envs/staging/backend.tf` and `infra/terraform/envs/prod/backend.tf`. Make sure `bucket` matches what you created above and `dynamodb_table` matches the table name.

---

## Phase 1 — Apply staging

All Terraform commands run from inside the env directory.

### 1.1 Initialize

```bash
cd infra/terraform/envs/staging
terraform init
```

Expected output:
- "Successfully configured the backend 's3'"
- All providers downloaded (aws ~> 5.0, random ~> 3.6)
- "Terraform has been successfully initialized!"

### 1.2 Format and validate

```bash
terraform fmt -recursive ../..
terraform validate
```

Both should be silent / "Success!".

### 1.3 Plan

```bash
terraform plan -out=staging.tfplan
```

Read the plan carefully. Expected counts (approximately):
- KMS: 2 keys + 2 aliases
- VPC: ~25 resources (VPC, subnets × 6, route tables × 3, NAT, EIP, IGW, endpoints × 6, subnet groups, security groups)
- Secrets: 5 secrets + 2 secret versions
- S3: 1 bucket + 6 supporting resources (PAB, encryption, versioning, lifecycle, CORS, notification) + policy
- SQS: 4 queues + 1 queue policy
- RDS: 1 instance + 1 parameter group + 1 security group
- Redis: 1 replication group + 1 parameter group + 1 security group
- Bastion: 1 instance + IAM role + instance profile + SG + 5 SG rules

Total ~70 resources. No `destroy` should appear on a fresh apply.

### 1.4 Apply

```bash
terraform apply staging.tfplan
```

This takes **20–30 minutes** for staging — most of it is RDS and Redis creation. You'll see resources come up in dependency order:
1. KMS keys (~30s)
2. VPC + subnets + endpoints (~3 min — interface endpoints are slow)
3. Secrets (~10s)
4. S3 + SQS (~30s)
5. RDS (~10–12 min)
6. Redis (~8–10 min)
7. Bastion (~1 min)

Coffee break.

### 1.5 Save the outputs

```bash
terraform output > /tmp/staging-outputs.txt
cat /tmp/staging-outputs.txt
```

You'll reference these in later phases. Don't commit this file — it contains ARNs that are not secret but are environment-specific.

---

## Phase 2 — Populate manual secrets

Three secrets are created as **empty containers** by the secrets module. They must be filled before any service can use them.

| Secret | Source | Format |
|---|---|---|
| `medical-ai/staging/claude/api-key` | Anthropic console → API keys | plain string, starts `sk-ant-...` |
| `medical-ai/staging/cohere/api-key` | Cohere dashboard → API keys | plain string |
| `medical-ai/staging/supabase/jwt-secret` | Supabase project → Settings → API → JWT Secret | plain string |

For each:

```bash
# Claude
aws secretsmanager put-secret-value \
  --secret-id medical-ai/staging/claude/api-key \
  --secret-string 'sk-ant-...'

# Cohere
aws secretsmanager put-secret-value \
  --secret-id medical-ai/staging/cohere/api-key \
  --secret-string 'your-cohere-key'

# Supabase JWT
aws secretsmanager put-secret-value \
  --secret-id medical-ai/staging/supabase/jwt-secret \
  --secret-string 'your-jwt-secret'
```

Verify (the value won't be shown — only metadata):
```bash
aws secretsmanager describe-secret --secret-id medical-ai/staging/claude/api-key
```

Look for `VersionIdsToStages` showing an `AWSCURRENT` version. If empty, the put failed.

---

## Phase 3 — Post-RDS database setup

The DB is running but doesn't have pgvector installed yet. This requires connecting to the DB, which requires the bastion (which is already up from Phase 1).

### 3.1 Open the SSM tunnel

```bash
# From repo root, terminal 1
./scripts/db-tunnel.sh staging postgres
```

Leave this running. Output:
```
→ Postgres tunnel: localhost:5432 → medical-ai-staging.xxx.ap-south-1.rds.amazonaws.com:5432
  bastion: i-0abc123...
  (Ctrl+C to close)
Waiting for connections...
```

### 3.2 Connect with psql

In terminal 2:
```bash
PGPASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id medical-ai/staging/rds/master \
  --query SecretString --output text | jq -r .password)

psql --host=localhost --port=5432 \
  --username=vaidya_admin --dbname=medical_ai "sslmode=require"
```

You should land at a `medical_ai=>` prompt.

### 3.3 Install pgvector

```sql
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Verify
SELECT extname, extversion FROM pg_extension ORDER BY extname;
```

Expected output includes:
- `pg_stat_statements`
- `plpgsql`
- `vector`

If `vector` is missing:
```sql
SELECT * FROM pg_available_extensions WHERE name = 'vector';
```
If this returns no rows, the parameter group didn't apply — see `infra/terraform/modules/rds/README.md` troubleshooting.

### 3.4 Smoke-test pgvector

```sql
SELECT '[1,2,3]'::vector;        -- should print [1,2,3]
SELECT '[1,2,3]'::vector <=> '[1,2,4]'::vector;  -- should print a small float (cosine distance)
```

Exit psql (`\q`), then Ctrl+C the tunnel in terminal 1.

---

## Phase 4 — Verify end-to-end

### 4.1 Verify Redis is reachable

Terminal 1:
```bash
./scripts/db-tunnel.sh staging redis
```

Terminal 2:
```bash
AUTH=$(aws secretsmanager get-secret-value \
  --secret-id medical-ai/staging/redis/auth-token \
  --query SecretString --output text)

redis-cli -h localhost -p 6379 --tls --insecure -a "$AUTH"
> PING
PONG
> CONFIG GET maxmemory-policy
1) "maxmemory-policy"
2) "allkeys-lru"
> QUIT
```

Close the tunnel.

### 4.2 Verify S3 → SQS event wiring

Upload a test object and confirm a message lands on the OCR queue.

```bash
# Get the bucket name
BUCKET=$(cd infra/terraform/envs/staging && terraform output -raw reports_bucket_name)
QUEUE_URL=$(cd infra/terraform/envs/staging && terraform output -raw ocr_jobs_queue_url)

# Upload a test file under the `uploads/` prefix
echo "test file" > /tmp/test.txt
aws s3 cp /tmp/test.txt "s3://${BUCKET}/uploads/test.txt"

# Wait a few seconds, then check the queue
sleep 5
aws sqs receive-message --queue-url "$QUEUE_URL" --max-number-of-messages 1
```

Expected: a message containing `s3:ObjectCreated:Put`, the bucket name, and the object key `uploads/test.txt`.

If the queue is empty:
- Confirm the upload landed under `uploads/` exactly (the prefix filter is strict)
- Check the bucket notification config: `aws s3api get-bucket-notification-configuration --bucket "$BUCKET"`
- Confirm the SQS queue policy allows the bucket: `aws sqs get-queue-attributes --queue-url "$QUEUE_URL" --attribute-names Policy`

Clean up the test message and file:
```bash
RECEIPT=$(aws sqs receive-message --queue-url "$QUEUE_URL" --max-number-of-messages 1 --query 'Messages[0].ReceiptHandle' --output text)
[ "$RECEIPT" != "None" ] && aws sqs delete-message --queue-url "$QUEUE_URL" --receipt-handle "$RECEIPT"
aws s3 rm "s3://${BUCKET}/uploads/test.txt"
```

### 4.3 Sanity-check encryption

```bash
# RDS storage is encrypted with our CMK
aws rds describe-db-instances --db-instance-identifier medical-ai-staging \
  --query 'DBInstances[0].{Encrypted:StorageEncrypted,KmsKeyId:KmsKeyId}'

# Redis transit encryption
aws elasticache describe-replication-groups --replication-group-id medical-ai-staging \
  --query 'ReplicationGroups[0].{AtRest:AtRestEncryptionEnabled,Transit:TransitEncryptionEnabled,Auth:AuthTokenEnabled}'

# S3 bucket encryption
aws s3api get-bucket-encryption --bucket "$BUCKET"
```

All should show `Encrypted: true` / encryption with a `kms:` ARN.

### 4.4 Confirm no public exposure

```bash
# RDS should not be publicly accessible
aws rds describe-db-instances --db-instance-identifier medical-ai-staging \
  --query 'DBInstances[0].PubliclyAccessible'   # → false

# S3 public access block — all four true
aws s3api get-public-access-block --bucket "$BUCKET"

# Bastion has no public IP
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=medical-ai-bastion-staging" \
  --query 'Reservations[0].Instances[0].PublicIpAddress'  # → null
```

If any of these come back with public access, **stop and investigate** — something has drifted from the Terraform config.

---

## Phase 5 — Apply prod

Repeat Phases 1–4 from the `envs/prod/` directory. Differences:

| Phase | Staging | Prod |
|---|---|---|
| 1.4 Apply time | 20–30 min | **35–50 min** (multi-AZ everywhere) |
| 2 Manual secrets | `medical-ai/staging/...` | `medical-ai/prod/...` (use real prod API keys, not staging keys) |
| 3 Bastion | exists | **does NOT exist** — there is no human-tunnel path to prod. To run `CREATE EXTENSION vector` on prod, either: (a) temporarily add the staging bastion's SG to the prod RDS SG's ingress (ugly, manual cleanup required), or (b) run the SQL via an EC2 instance launched specifically for this bootstrap and then terminated. Document whichever you chose. |
| 4.2 S3 test | Use `uploads/test.txt` and delete | **Do not put real test data into the prod bucket.** Use a clearly-named throwaway object and delete it immediately. |

### Prod-specific risks to flag

- `deletion_protection = true` on RDS and `skip_final_snapshot = false` mean a `terraform destroy` on prod will be partially blocked, leaving orphaned resources. **Never** run destroy against prod without explicit team review.
- Multi-AZ Redis snapshots are stored cross-AZ; first apply may take longer than estimates suggest. Be patient before assuming a hang.
- Prod has no bastion by design. Plan how to handle one-off DB operations (rotations, manual extension installs) before you need to do one.

---

## Common bootstrap issues

### `Error: Error creating S3 bucket: BucketAlreadyExists`

Bucket names are globally unique. Someone (perhaps a previous you) already took the name. Pick a different suffix in `backend.tf` and re-run Phase 0.

### `Error: state snapshot was created by Terraform v1.x.x, which is newer than current v1.y.y`

Your local Terraform is older than the version that last wrote state. Upgrade Terraform: `brew upgrade terraform`.

### `Error acquiring the state lock — LockID: ...`

A previous `terraform` command was killed mid-run and left the lock held. If you're sure no other apply is running:

```bash
terraform force-unlock <LockID>
```

Only use this when you're certain. Concurrent applies will corrupt state.

### `Error: error reading Secrets Manager Secret (...) — DecryptionFailure`

The KMS key used to encrypt the secret was deleted or its policy doesn't allow the calling IAM role. For a fresh bootstrap, this usually means the KMS module didn't apply before the secrets module — re-run `terraform apply`.

### RDS apply hangs at "Still creating... (15m elapsed)"

Normal for multi-AZ. Wait. If it reaches 30 minutes without progress, check the RDS console — usually a misconfigured parameter group prevents reboot. The error message there is more specific than what Terraform shows.

### `Error: SubnetGroupNotFoundFault`

The order of resource creation got confused (rare but possible with `-target`). Run a clean `terraform plan` without `-target`; the dependency graph will re-resolve.

### "Plan: 0 to add, 0 to change, 0 to destroy" on a fresh apply

You're pointed at an already-applied state. Check `terraform workspace show` and `cat backend.tf` — likely you're using an existing state bucket someone else's apply has already populated.

### Tunnel script: `Error: TargetNotConnected`

The bastion is stopped or its SSM agent hasn't registered. Wait 2 minutes after `terraform apply` finishes — registration takes time. If it still fails after 5 minutes:

```bash
INSTANCE_ID=$(cd infra/terraform/envs/staging && terraform output -raw bastion_instance_id)
aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$INSTANCE_ID"
```

If empty, the bastion can't reach the SSM control plane. Check the NAT gateway status in the VPC dashboard.

### `terraform apply` plan looks right but apply fails on RDS with `InvalidParameterCombination: shared_preload_libraries`

The parameter group has the wrong family. Check `aws_db_parameter_group.main.family` matches the engine version (`postgres16` for Postgres 16). If you bumped `engine_version`, also bump `family`.

---

## After bootstrap — what to do next

1. **Save the bootstrap notes.** Write down in your team channel: the account ID, the state bucket name, the date of first apply, the prod-specific decision for bootstrap DB access. This becomes the audit trail.
2. **Restrict IAM.** Replace your admin user/role with least-privilege roles per team member. Bootstrap permissions are too broad to leave in place.
3. **Set up billing alerts.** A misconfigured NAT gateway or RDS Multi-AZ can quietly cost hundreds. AWS Budgets at $50, $100, $250 thresholds.
4. **Schedule the first credential rotation.** RDS master, Redis AUTH — set a calendar reminder for 90 days.
5. **Start Sprint 2.** Compute (Fargate API + Lambda worker) is the next set of modules. The infrastructure outputs from this bootstrap are exactly what the compute modules consume as inputs.

---

## Quick reference — Phase commands

```bash
# Phase 0 (one-time per account)
aws s3api create-bucket --bucket "medical-ai-terraform-state-${ACCOUNT_ID}" ...
aws dynamodb create-table --table-name medical-ai-terraform-locks ...

# Phase 1 (per env)
cd infra/terraform/envs/staging
terraform init
terraform fmt -recursive ../..
terraform validate
terraform plan -out=staging.tfplan
terraform apply staging.tfplan

# Phase 2 (one-time per env)
aws secretsmanager put-secret-value --secret-id medical-ai/staging/claude/api-key --secret-string '...'
aws secretsmanager put-secret-value --secret-id medical-ai/staging/cohere/api-key --secret-string '...'
aws secretsmanager put-secret-value --secret-id medical-ai/staging/supabase/jwt-secret --secret-string '...'

# Phase 3 (one-time per env)
./scripts/db-tunnel.sh staging postgres                # terminal 1
psql ... -c "CREATE EXTENSION vector;"                 # terminal 2

# Phase 4 (verify)
aws s3 cp /tmp/test.txt s3://${BUCKET}/uploads/test.txt
aws sqs receive-message --queue-url $QUEUE_URL
```
