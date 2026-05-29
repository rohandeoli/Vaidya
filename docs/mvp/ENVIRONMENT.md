# Environment variables

Copy `.env.example` to `.env.local` for local development.
In staging and production, all secrets are stored in AWS Secrets Manager — never in env files.

## Required for all environments

```bash
# ── Database ──────────────────────────────────────────────────────────
DATABASE_URL=postgresql+asyncpg://user:pass@host:5432/medicalai
# RDS endpoint in ap-south-1 for staging/prod
# docker-compose postgres for local (see REPO_STRUCTURE.md)

# ── Supabase Auth ─────────────────────────────────────────────────────
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_SERVICE_KEY=eyJ...   # Backend only — never expose to client
SUPABASE_ANON_KEY=eyJ...      # Safe for client bundle (NEXT_PUBLIC_*)
NEXT_PUBLIC_SUPABASE_URL=https://your-project.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=eyJ...

# ── AWS ───────────────────────────────────────────────────────────────
AWS_ACCESS_KEY_ID=AKIA...
AWS_SECRET_ACCESS_KEY=...
AWS_REGION=ap-south-1         # Must be Mumbai for data residency

# ── S3 ────────────────────────────────────────────────────────────────
S3_BUCKET_NAME=medical-ai-reports-prod
S3_PRESIGNED_URL_TTL=900       # 15 minutes in seconds

# ── SQS ───────────────────────────────────────────────────────────────
SQS_OCR_QUEUE_URL=https://sqs.ap-south-1.amazonaws.com/123456789/medical-ai-ocr-jobs
SQS_EXTRACTION_QUEUE_URL=https://sqs.ap-south-1.amazonaws.com/123456789/medical-ai-extraction-jobs

# ── AI ────────────────────────────────────────────────────────────────
ANTHROPIC_API_KEY=sk-ant-...
ANTHROPIC_MODEL=claude-sonnet-4-20250514
ANTHROPIC_MAX_TOKENS=1200
ANTHROPIC_TEMPERATURE=0.2

# ── Embeddings ────────────────────────────────────────────────────────
COHERE_API_KEY=...
COHERE_EMBED_MODEL=embed-multilingual-v3
COHERE_EMBED_INPUT_TYPE=search_document   # for KB indexing
# search_query for query-time embedding

# ── Redis ─────────────────────────────────────────────────────────────
REDIS_URL=redis://localhost:6379/0
# Rule: no PHI stored here. Sessions and rate limits only.

# ── Encryption ────────────────────────────────────────────────────────
AWS_KMS_KEY_ID=arn:aws:kms:ap-south-1:123456789:key/...
# Used for field-level encryption (health_context, raw_extracted)

# ── Frontend ──────────────────────────────────────────────────────────
NEXT_PUBLIC_API_URL=http://localhost:8000   # FastAPI base URL
# staging: https://api-staging.yourdomain.com
# prod:    https://api.yourdomain.com
```

## Optional (not needed for local dev)

```bash
# ── Virus scanning ────────────────────────────────────────────────────
CLAMAV_HOST=localhost
CLAMAV_PORT=3310
# Skip in local dev if ClamAV not installed — enforced in staging/prod

# ── Observability ─────────────────────────────────────────────────────
SENTRY_DSN=https://...@sentry.io/...
SENTRY_ENVIRONMENT=local|staging|production

DATADOG_API_KEY=...
DD_SERVICE=medical-ai-api
DD_ENV=staging

# ── PII Detection ─────────────────────────────────────────────────────
AWS_COMPREHEND_REGION=ap-south-1
# Uses same AWS credentials — separate entry in case region differs

# ── Feature flags ─────────────────────────────────────────────────────
ENABLE_CLAMAV=false        # Set true in staging/prod
ENABLE_AUDIT_LOG=true      # Never set false in prod
OCR_CONFIDENCE_THRESHOLD=0.85
MAX_UPLOAD_SIZE_MB=10
```

## Local dev overrides (`.env.local`)

```bash
# LocalStack replaces real AWS services locally
AWS_ENDPOINT_URL=http://localhost:4566    # LocalStack endpoint
S3_BUCKET_NAME=medical-ai-reports-local
SQS_OCR_QUEUE_URL=http://localhost:4566/000000000000/medical-ai-ocr-jobs
SQS_EXTRACTION_QUEUE_URL=http://localhost:4566/000000000000/medical-ai-extraction-jobs

# Disable ClamAV locally (most devs won't have it running)
ENABLE_CLAMAV=false

# Lower confidence threshold for testing with synthetic reports
OCR_CONFIDENCE_THRESHOLD=0.70
```

## Secret rotation policy

| Secret | Rotation frequency |
|---|---|
| `ANTHROPIC_API_KEY` | On any suspected exposure; otherwise quarterly |
| `AWS_ACCESS_KEY_ID` | 90 days (IAM policy enforced) |
| `COHERE_API_KEY` | Quarterly |
| `SUPABASE_SERVICE_KEY` | On any suspected exposure |
| `AWS_KMS_KEY_ID` (key material) | Annual (AWS KMS automatic rotation enabled) |
| Database password | 90 days via AWS Secrets Manager rotation |

## IAM permissions for `AWS_ACCESS_KEY_ID`

The IAM user/role must have exactly these permissions — no more:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:GeneratePresignedUrl"
      ],
      "Resource": "arn:aws:s3:::medical-ai-reports-*/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "sqs:SendMessage",
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes"
      ],
      "Resource": "arn:aws:sqs:ap-south-1:*:medical-ai-*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "textract:StartDocumentAnalysis",
        "textract:GetDocumentAnalysis",
        "textract:AnalyzeDocument"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "comprehend:DetectPiiEntities",
        "comprehendmedical:DetectEntitiesV2"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:GenerateDataKey"
      ],
      "Resource": "arn:aws:kms:ap-south-1:*:key/YOUR_KEY_ID"
    }
  ]
}
```
