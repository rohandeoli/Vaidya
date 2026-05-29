# Repository structure & setup

## Monorepo layout

```
medical-ai/
│
├── CLAUDE.md                        # Claude Code entry point — read this first
├── README.md
├── turbo.json                       # Turborepo pipeline config
├── package.json                     # Root workspace (pnpm)
├── pnpm-workspace.yaml
│
├── apps/
│   └── web/                         # Next.js 14 (App Router)
│       ├── app/
│       │   ├── (auth)/
│       │   │   ├── login/
│       │   │   │   └── page.tsx
│       │   │   ├── signup/
│       │   │   │   └── page.tsx
│       │   │   └── consent/
│       │   │       └── page.tsx     # Consent flow — required before first use
│       │   ├── (app)/               # Protected — requires auth + consent
│       │   │   ├── layout.tsx
│       │   │   ├── upload/
│       │   │   │   └── page.tsx
│       │   │   ├── reports/
│       │   │   │   ├── [id]/
│       │   │   │   │   └── page.tsx # Results screen
│       │   │   │   └── page.tsx     # Report list (stub in MVP — "no reports yet")
│       │   │   └── settings/
│       │   │       └── page.tsx     # Consent management + account deletion
│       │   ├── layout.tsx
│       │   └── globals.css
│       ├── components/
│       │   ├── ui/                  # Primitives: Button, Card, Badge, Spinner
│       │   ├── upload/
│       │   │   ├── UploadZone.tsx
│       │   │   ├── UploadProgress.tsx
│       │   │   └── ConfidenceConfirm.tsx  # Low-confidence field confirmation
│       │   └── results/
│       │       ├── ExplanationStream.tsx  # SSE streaming text renderer
│       │       ├── BiomarkerCard.tsx      # Per-test card with status + citations
│       │       ├── UrgencyBanner.tsx      # 4-tier urgency display
│       │       ├── DoctorQuestions.tsx
│       │       ├── Citations.tsx
│       │       └── Disclaimer.tsx        # Always-visible, cannot be hidden
│       ├── lib/
│       │   ├── api.ts               # Typed API client (fetch wrapper)
│       │   ├── streaming.ts         # SSE consumer helper
│       │   ├── supabase.ts          # Supabase client (browser)
│       │   └── supabase-server.ts   # Supabase client (server components)
│       ├── hooks/
│       │   ├── useUpload.ts
│       │   └── useReportStream.ts
│       ├── next.config.ts
│       ├── tsconfig.json
│       └── package.json
│
├── services/
│   └── api/                         # FastAPI — main backend
│       ├── main.py                  # App entry point, middleware registration
│       ├── config.py                # Pydantic settings (reads from env)
│       ├── routers/
│       │   ├── auth.py              # /auth/* — thin proxy to Supabase
│       │   ├── reports.py           # /reports/* — upload, status, retrieve
│       │   ├── ai.py                # /ai/* — explain endpoint (SSE)
│       │   └── health.py            # /health — liveness + readiness
│       ├── services/
│       │   ├── ingestion/
│       │   │   ├── __init__.py
│       │   │   ├── parser.py        # File type routing (PDF/image/HL7 stub)
│       │   │   ├── ocr.py           # AWS Textract wrapper
│       │   │   ├── extractor.py     # Structured data extraction + normalisation
│       │   │   └── confidence.py    # Confidence scoring + flag logic
│       │   ├── orchestration/
│       │   │   ├── __init__.py
│       │   │   ├── pipeline.py      # Main orchestration flow (9 stages)
│       │   │   ├── pii.py           # Tokenization middleware
│       │   │   ├── prompt.py        # Block assembly from DB
│       │   │   ├── safety.py        # Input classifier + output validation
│       │   │   └── urgency.py       # Rule engine + AI urgency resolution
│       │   └── rag/
│       │       ├── __init__.py
│       │       ├── retriever.py     # Dense search (+ reranker pass-through)
│       │       ├── embedder.py      # Cohere embed wrapper
│       │       └── context.py       # Chunk selection + prompt block injection
│       ├── models/                  # SQLAlchemy ORM models
│       │   ├── user.py
│       │   ├── report.py
│       │   ├── biomarker.py
│       │   ├── audit.py
│       │   ├── kb_chunk.py
│       │   └── prompt_block.py
│       ├── db/
│       │   ├── session.py           # Async SQLAlchemy engine + session
│       │   ├── migrations/          # Alembic
│       │   │   ├── env.py
│       │   │   └── versions/
│       │   └── seeds/
│       │       ├── emergency_templates.py
│       │       └── prompt_blocks.py
│       ├── middleware/
│       │   ├── auth.py              # JWT validation
│       │   ├── consent.py           # Consent check before AI endpoints
│       │   └── audit.py             # Request/response audit logging
│       ├── requirements.txt
│       ├── Dockerfile
│       └── pyproject.toml
│
├── workers/
│   └── ingestion/                   # Async SQS consumer
│       ├── main.py                  # Worker entry point
│       ├── consumer.py              # SQS long-poll loop
│       ├── jobs/
│       │   ├── ocr_job.py           # Textract call + result storage
│       │   └── extract_job.py       # Structured extraction + DB writes
│       ├── Dockerfile
│       └── requirements.txt
│
├── kb/                              # Knowledge base management
│   ├── ingestion/
│   │   ├── chunker.py               # Per-type chunking strategies
│   │   ├── embedder.py              # Batch Cohere embedding
│   │   └── validator.py             # Schema validation (chunk_schema)
│   ├── sources/                     # Source documents (gitignored — too large)
│   │   └── .gitkeep
│   ├── chunks/                      # Approved chunk JSON (version controlled)
│   │   └── starter/
│   │       └── icmr_who_top20.json  # 500-chunk starter set
│   └── scripts/
│       ├── seed.py                  # Load chunks → DB (idempotent)
│       └── benchmark.py             # 30-query RAG benchmark test
│
├── infra/
│   └── terraform/
│       ├── modules/
│       │   ├── rds/                 # PostgreSQL + pgvector, ap-south-1
│       │   ├── s3/                  # Reports bucket
│       │   ├── sqs/                 # OCR + extraction queues + DLQs
│       │   ├── ecs/                 # ECS Fargate for api + worker
│       │   ├── ecr/                 # Container registry
│       │   └── secrets/             # AWS Secrets Manager
│       ├── envs/
│       │   ├── staging/
│       │   │   └── main.tf
│       │   └── prod/
│       │       └── main.tf
│       └── variables.tf
│
├── docs/                            # Architecture documentation
│   ├── README.md
│   ├── architecture/
│   ├── safety/
│   ├── rag/
│   └── mvp/                         # ← This document + siblings
│
└── scripts/
    ├── setup_local.sh               # One-command local dev setup
    └── smoke_test.py                # End-to-end smoke test against staging
```

---

## Turborepo configuration

`turbo.json`:
```json
{
  "$schema": "https://turbo.build/schema.json",
  "pipeline": {
    "build": {
      "dependsOn": ["^build"],
      "outputs": [".next/**", "dist/**"]
    },
    "dev": {
      "cache": false,
      "persistent": true
    },
    "lint": {},
    "test": {
      "dependsOn": ["build"]
    },
    "type-check": {
      "dependsOn": ["^build"]
    }
  }
}
```

`pnpm-workspace.yaml`:
```yaml
packages:
  - 'apps/*'
```

Note: Python services (`services/api`, `workers/ingestion`) are not in the pnpm workspace — they are managed independently with their own `requirements.txt` and `pyproject.toml`. Turborepo still orchestrates their `build` and `dev` tasks via shell commands in the pipeline.

---

## Local development setup

`scripts/setup_local.sh`:
```bash
#!/bin/bash
set -e

echo "→ Checking prerequisites..."
command -v docker >/dev/null 2>&1 || { echo "Docker required"; exit 1; }
command -v pnpm >/dev/null 2>&1 || { echo "pnpm required: npm i -g pnpm"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "Python 3.11+ required"; exit 1; }

echo "→ Installing JS dependencies..."
pnpm install

echo "→ Starting local services (Postgres + Redis + LocalStack)..."
docker compose up -d

echo "→ Waiting for Postgres..."
sleep 3

echo "→ Running DB migrations..."
cd services/api && python -m alembic upgrade head && cd ../..

echo "→ Seeding prompt blocks and emergency templates..."
cd services/api && python db/seeds/prompt_blocks.py && python db/seeds/emergency_templates.py && cd ../..

echo "→ Seeding starter KB..."
python kb/scripts/seed.py --env local

echo "→ Running RAG benchmark..."
python kb/scripts/benchmark.py --env local

echo "✓ Setup complete. Run 'pnpm dev' to start all services."
```

`docker-compose.yml` (local dev only):
```yaml
services:
  postgres:
    image: pgvector/pgvector:pg16
    environment:
      POSTGRES_DB: medicalai
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: localdev
    ports:
      - "5432:5432"
    volumes:
      - pgdata:/var/lib/postgresql/data

  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"

  localstack:
    image: localstack/localstack
    ports:
      - "4566:4566"
    environment:
      SERVICES: s3,sqs,textract
      DEFAULT_REGION: ap-south-1

volumes:
  pgdata:
```

---

## SQS queue design

Two queues in MVP. Each has a corresponding Dead Letter Queue (DLQ).

### `medical-ai-ocr-jobs` (Standard)

Producer: `POST /reports/{id}/confirm` in the API service
Consumer: ingestion worker

Message schema:
```json
{
  "report_id": "uuid",
  "user_id": "uuid",
  "s3_key": "reports/uuid/original.pdf",
  "file_type": "pdf_digital | pdf_scanned | image",
  "uploaded_at": "2025-05-20T10:30:00Z"
}
```

Config:
- Visibility timeout: 120s (Textract can take up to 90s for large scans)
- Max receive count before DLQ: 3
- DLQ retention: 14 days

### `medical-ai-extraction-jobs` (Standard)

Producer: OCR worker (after Textract completes)
Consumer: ingestion worker (extraction stage)

Message schema:
```json
{
  "report_id": "uuid",
  "user_id": "uuid",
  "textract_job_id": "string",
  "ocr_output_s3_key": "ocr-results/uuid/textract.json"
}
```

Config:
- Visibility timeout: 60s
- Max receive count before DLQ: 3
- DLQ retention: 14 days

### DLQ alerting
CloudWatch alarm: any message hitting the DLQ triggers a PagerDuty/email alert. A failed OCR or extraction job must never silently disappear — the user needs to see an error state, not a spinner that never resolves.

Worker pattern:
```python
# workers/ingestion/consumer.py
import boto3, json, time

sqs = boto3.client("sqs", region_name="ap-south-1")

def poll(queue_url: str, handler):
    while True:
        response = sqs.receive_message(
            QueueUrl=queue_url,
            MaxNumberOfMessages=10,
            WaitTimeSeconds=20,      # Long polling — reduces empty receives
            VisibilityTimeout=120
        )
        for msg in response.get("Messages", []):
            try:
                body = json.loads(msg["Body"])
                handler(body)
                sqs.delete_message(
                    QueueUrl=queue_url,
                    ReceiptHandle=msg["ReceiptHandle"]
                )
            except Exception as e:
                # Log error — message returns to queue after visibility timeout
                # After max_receive_count it goes to DLQ
                print(f"Job failed: {e}")
```

---

## SSE streaming pattern

### FastAPI endpoint
```python
# services/api/routers/ai.py
from fastapi import APIRouter
from fastapi.responses import StreamingResponse
import anthropic, json

router = APIRouter()

@router.get("/reports/{report_id}/explain")
async def explain(report_id: str, query: str, user=Depends(get_current_user)):
    async def stream():
        # Run full orchestration pipeline up to Claude call
        context = await build_context(report_id, query, user)

        client = anthropic.AsyncAnthropic()
        async with client.messages.stream(
            model="claude-sonnet-4-20250514",
            max_tokens=1200,
            temperature=0.2,
            system=context.system_prompt,
            messages=[{"role": "user", "content": context.user_message}]
        ) as stream:
            async for text in stream.text_stream:
                yield f"data: {json.dumps({'type': 'text', 'content': text})}\n\n"

        # After stream completes, send structured data
        final = await stream.get_final_message()
        validated = validate_output(final, context.retrieved_chunks)
        yield f"data: {json.dumps({'type': 'structured', 'content': validated})}\n\n"
        yield "data: [DONE]\n\n"

    return StreamingResponse(stream(), media_type="text/event-stream")
```

### Next.js consumer
```typescript
// apps/web/hooks/useReportStream.ts
export function useReportStream(reportId: string, query: string) {
  const [explanation, setExplanation] = useState("")
  const [structured, setStructured] = useState<StructuredOutput | null>(null)
  const [status, setStatus] = useState<"idle"|"streaming"|"done"|"error">("idle")

  const start = useCallback(async () => {
    setStatus("streaming")
    const res = await fetch(`/api/reports/${reportId}/explain?query=${encodeURIComponent(query)}`)
    const reader = res.body!.getReader()
    const decoder = new TextDecoder()

    while (true) {
      const { done, value } = await reader.read()
      if (done) break
      const lines = decoder.decode(value).split("\n\n")
      for (const line of lines) {
        if (!line.startsWith("data: ")) continue
        const data = line.slice(6)
        if (data === "[DONE]") { setStatus("done"); break }
        const msg = JSON.parse(data)
        if (msg.type === "text") setExplanation(prev => prev + msg.content)
        if (msg.type === "structured") setStructured(msg.content)
      }
    }
  }, [reportId, query])

  return { explanation, structured, status, start }
}
```

---

## Direct S3 upload pattern

```
1. Client calls  POST /reports/upload-url
                 Body: { filename, content_type, file_size }

2. API returns   { report_id, upload_url, fields }
                 (pre-signed POST URL, 15-min TTL)

3. Client POSTs  file directly to S3 upload_url
                 (never passes through your API server)

4. Client calls  POST /reports/{report_id}/confirm
                 (tells API the upload is complete)

5. API enqueues  OCR job to SQS
                 Returns { status: "processing" }

6. Client polls  GET /reports/{report_id}/status
                 Until status = "ready" | "error"
```

FastAPI pre-signed URL generation:
```python
# services/api/routers/reports.py
import boto3, uuid
from datetime import datetime

s3 = boto3.client("s3", region_name="ap-south-1")

@router.post("/upload-url")
async def get_upload_url(body: UploadRequest, user=Depends(get_current_user)):
    report_id = str(uuid.uuid4())
    s3_key = f"reports/{user.id}/{report_id}/original"

    # Validate file type and size before issuing URL
    if body.file_size > 10 * 1024 * 1024:  # 10MB
        raise HTTPException(400, "File too large")
    if body.content_type not in ALLOWED_TYPES:
        raise HTTPException(400, "Unsupported file type")

    presigned = s3.generate_presigned_post(
        Bucket=settings.S3_BUCKET,
        Key=s3_key,
        Fields={"Content-Type": body.content_type},
        Conditions=[
            {"Content-Type": body.content_type},
            ["content-length-range", 1, 10 * 1024 * 1024]
        ],
        ExpiresIn=900   # 15 minutes
    )

    # Create report record in DB (status: pending_upload)
    await db.reports.create(report_id=report_id, user_id=user.id, s3_key=s3_key)

    return {"report_id": report_id, **presigned}
```
