# Security & compliance

## Encryption

### In transit
- TLS 1.3 on all connections, no version fallback permitted
- Internal service-to-service communication also encrypted (mTLS)

### At rest
- AES-256 server-side encryption on all S3/GCS objects
- PostgreSQL: transparent data encryption + pgcrypto for field-level encryption on sensitive columns
- Key management via AWS KMS or GCP KMS — keys never stored in application code or env files
- 90-day key rotation policy with key versioning

### Field-level encryption targets (pgcrypto)
Columns that are encrypted at the field level in addition to disk-level encryption:
- `users.health_context` (conditions, medications)
- `reports.raw_extracted_text`
- `ai_conversations.prompt_log`
- Any column containing scan findings or radiologist notes

---

## PII tokenization (mandatory before any external API call)

This is the most commonly skipped critical step. It is non-negotiable.

### What gets tokenized
Before any data is sent to Claude API, OCR engine, or embeddings API, the following are detected and replaced with reversible UUID tokens:

- Full name
- Date of birth
- Phone number
- Email address
- Home address
- Hospital patient ID
- Any Aadhaar-linked reference numbers
- Bank account or insurance numbers

### How it works

```
1. Input payload arrives at AI orchestration service
2. AWS Comprehend Medical (or custom NER) scans for PII entities
3. Each detected entity is replaced with a UUID token
4. Token → original value mapping stored in Redis (short TTL, server-side only)
5. Tokenized payload is sent to external API
6. Response is received
7. Tokens in response are replaced with original values before returning to client
8. Token map is deleted from Redis
```

### Implementation rule
A pre-send validation check runs on every outbound payload to external APIs. If any token pattern is missing for a detected PII entity, the request is aborted — never send unmasked PII even if the tokenizer partially fails.

---

## Audit logging

### What is logged (immutable, append-only)
Every one of these events creates an audit record that cannot be modified or deleted:

- User login / logout / failed login
- File upload (file type, size, hash — not content)
- OCR job start / complete / fail
- Every AI query (prompt version, model, latency, urgency output)
- Report accessed / viewed / exported
- Any admin action on user data
- Consent record creation / withdrawal

### Storage
Append-only PostgreSQL table with RLS policy that blocks DELETE and UPDATE. Only INSERT is permitted for application service accounts.

```sql
-- No application role can delete or update audit records
CREATE POLICY audit_insert_only ON audit_log
  FOR INSERT TO app_service_role WITH CHECK (true);
-- No SELECT policy for non-admin roles — audit data is not exposed in the app
```

Replicated to CloudWatch Logs or Datadog SIEM for anomaly detection.

### Anomaly detection triggers
- User downloading all their records in a single session
- Admin querying more than 20 user profiles in an hour
- API access from a new country/IP not matching user's history
- Bulk export of report data

---

## Compliance frameworks

### DPDP Act 2023 (India) — primary framework

Key requirements and how they are met:

| Requirement | Implementation |
|---|---|
| Explicit, granular consent | One consent record per processing purpose — not a single blanket consent |
| Right to access | User can export all their data in JSON/PDF from the app |
| Right to erasure | S3 lifecycle deletion + PostgreSQL soft delete with scheduled hard delete |
| Data localisation | All PHI stored in AWS Mumbai / GCP Mumbai region exclusively |
| Data fiduciary registration | Register as a significant data fiduciary if user base exceeds threshold |
| Breach notification | Automated workflow triggers on anomaly detection; 72-hour notification target |

### HIPAA (if serving US users)
If the product is extended to US users, the following additions are required:
- BAA (Business Associate Agreement) with AWS/GCP, Cohere, Anthropic
- PHI access logs must be accessible to users on request (HIPAA Right of Access)
- Minimum necessary standard — only access PHI required for the specific function

### Consent schema

```json
{
  "consent_id": "uuid",
  "user_id": "uuid",
  "purpose": "report_analysis | health_context_storage | trend_tracking | notifications",
  "granted": true,
  "granted_at": "2025-01-15T10:30:00Z",
  "withdrawn_at": null,
  "version": "consent_policy_v2.1",
  "ip_address": "redacted_after_30_days"
}
```

---

## Object storage access rules

Raw uploaded files (PDFs, images, scans) are never publicly accessible.

- All access via pre-signed URLs with 15-minute TTL
- Pre-signed URL generation requires a valid authenticated session
- URLs are single-use (invalidated after first successful download)
- S3 bucket policy explicitly denies all public access
- Versioning enabled on the bucket — accidental deletes are recoverable for 30 days
- Lifecycle policy: delete originals after user account deletion (right to erasure)

---

## Redis — no PHI rule

Redis is used only for:
- User session tokens (JWT refresh tokens, short TTL)
- API rate limit counters (per user, per endpoint)
- Anonymized reference-range lookup cache (public medical data, no user association)

It is never used for:
- Report content
- AI conversation history
- Biomarker values
- Any field containing user health information

CI/CD pipeline includes a lint check that scans cache-write code paths for patterns that resemble PHI (names, dates, lab values). The build fails if any such pattern is found without explicit exemption review.
