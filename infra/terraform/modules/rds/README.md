# RDS post-apply runbook

What to do after `terraform apply` of the rds module succeeds. These are one-time bootstrap steps per environment — not part of Terraform because they live *inside* the database, not in AWS.

---

## Prerequisites

Before running any of this you need:

1. **RDS apply finished cleanly.** `terraform output db_endpoint` returns a hostname.
2. **A network path to the DB.** The RDS security group has no ingress rules; you cannot reach the DB from your laptop until one of these is in place:
   - The bastion module is applied and you can run `scripts/db-tunnel.sh` (recommended)
   - You have temporarily added an ingress rule on the RDS SG from another VPC source (AWS CloudShell, an existing EC2 instance, etc.)
3. **psql installed locally** (`brew install libpq && brew link --force libpq`) — or you can run psql from the bastion itself.
4. **AWS CLI configured** with credentials that can read the rds master secret.

---

## Step 1 — Get connection details

```bash
cd infra/terraform/envs/staging      # or envs/prod

# Endpoint + db name
terraform output db_endpoint
terraform output db_name

# Master credentials (JSON)
aws secretsmanager get-secret-value \
  --secret-id "medical-ai/staging/rds/master" \
  --query SecretString --output text | jq
```

You should see `{ "username": "vaidya_admin", "password": "..." }`.

---

## Step 2 — Open the tunnel (once the bastion exists)

In a separate terminal, leave this running:

```bash
bash scripts/db-tunnel.sh staging
```

This forwards `localhost:5432` → bastion → RDS endpoint. Closing the terminal closes the tunnel.

---

## Step 3 — Connect with psql

```bash
PGPASSWORD='<password from step 1>' psql \
  --host=localhost \
  --port=5432 \
  --username=vaidya_admin \
  --dbname=medical_ai \
  "sslmode=require"
```

`sslmode=require` is mandatory — the parameter group sets `rds.force_ssl = 1`, so plaintext connections are refused.

Expected: a `medical_ai=>` prompt.

---

## Step 4 — Install extensions

pgvector and pg_stat_statements are preloaded by the parameter group (`shared_preload_libraries`), but each must be opted into per-database with `CREATE EXTENSION`.

```sql
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
```

Verify:

```sql
SELECT extname, extversion FROM pg_extension ORDER BY extname;
```

You should see `vector` and `pg_stat_statements` in the list (along with default extensions like `plpgsql`).

---

## Step 5 — Sanity checks

### TLS is enforced
Confirm the server refuses non-TLS:

```bash
PGPASSWORD='...' psql --host=localhost --port=5432 \
  --username=vaidya_admin --dbname=medical_ai \
  "sslmode=disable" -c "SELECT 1;"
```

Expected: `FATAL: no pg_hba.conf entry for host ... user "vaidya_admin", database "medical_ai", no encryption`.

### pgvector works
```sql
SELECT '[1,2,3]'::vector;
```

Expected output: `[1,2,3]`.

### Postgres version
```sql
SELECT version();
```

Expected: `PostgreSQL 16.x ...`.

---

## Step 6 — Record the moment

Note in the team channel / project log:
- Date of first apply
- Environment (staging / prod)
- Postgres version reported by `SELECT version()`
- That extensions were installed

This becomes the baseline for migration history.

---

## Things you do NOT do here

These belong elsewhere — listed so you don't accidentally do them now:

- **Create application tables.** That's the API service's job, via Alembic migrations.
- **Create RLS policies.** Same — defined as part of the migrations that create each table.
- **Create the application database user.** Will be created by an Alembic migration as a least-privilege role separate from `vaidya_admin`.
- **Load seed data.** Done by `services/api/db/seeds/` once the API exists.
- **Rotate the master password.** See "Rotation" below.

---

## Rotation (when you eventually need it)

Because the rds module has `lifecycle.ignore_changes = [password]`, rotating the master password is a deliberate two-step process — Terraform will not do it automatically when you change the secret.

1. Update the secret in Secrets Manager:
   ```bash
   aws secretsmanager put-secret-value \
     --secret-id "medical-ai/staging/rds/master" \
     --secret-string '{"username":"vaidya_admin","password":"NEW_PASSWORD"}'
   ```
2. Apply the new password to the DB:
   ```bash
   aws rds modify-db-instance \
     --db-instance-identifier medical-ai-staging \
     --master-user-password 'NEW_PASSWORD' \
     --apply-immediately
   ```
3. Restart any service holding open connections so it re-reads from Secrets Manager.

Never modify the DB password through Terraform — the `ignore_changes` will fight you.

---

## Troubleshooting

**`psql: error: connection to server at "localhost" failed: Connection refused`**
The SSM tunnel isn't running. Check the other terminal where `db-tunnel.sh` is supposed to be live.

**`FATAL: password authentication failed for user "vaidya_admin"`**
The password you typed doesn't match the secret. Re-fetch from Secrets Manager and copy exactly — note that `aws secretsmanager get-secret-value` returns JSON, so use `jq -r .password` to strip quotes.

**`FATAL: no pg_hba.conf entry ... no encryption`**
You connected with `sslmode=disable`. Re-run with `sslmode=require`.

**`ERROR: could not load library "vector": ...` when creating the extension**
The DB hasn't rebooted since the parameter group was applied. Check the AWS console — RDS dashboard → Modify → Pending modifications. If `shared_preload_libraries` is listed there, reboot manually:
```bash
aws rds reboot-db-instance --db-instance-identifier medical-ai-staging
```
Wait ~3 minutes, then retry the CREATE EXTENSION.

**Tunnel disconnects after a few minutes**
SSM port-forwarding sessions idle out. Re-run `db-tunnel.sh`. For long-running work, run psql commands non-interactively or open multiple tunnels.
