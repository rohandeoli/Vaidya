# CLAUDE.md

This is the entry point for Claude Code. Read this before touching any file.

## What this project is

A medical AI assistant that helps users understand their health reports and lab results in plain language. It explains biomarker values, flags abnormal results, and helps users prepare questions for their doctor.

**It never diagnoses. It never prescribes. It never replaces a doctor.**

Every engineering decision flows from this constraint.

## Architecture documentation

All design decisions are documented in `docs/`. Read the relevant doc before implementing any feature.

| You are working on | Read first |
|---|---|
| Any AI feature | `docs/safety/AI_ORCHESTRATION.md` + `docs/safety/PROMPT_ARCHITECTURE.md` |
| Safety rules or guardrails | `docs/safety/GUARDRAILS.md` + `docs/safety/URGENCY_MATRIX.md` |
| RAG or knowledge base | `docs/rag/RAG_PIPELINE.md` + `docs/rag/CHUNK_SCHEMA.md` |
| Database schema | `docs/architecture/DATA_MODEL.md` |
| Security, encryption, PII | `docs/architecture/SECURITY.md` |
| MVP scope and sprint plan | `docs/mvp/MVP.md` |
| Repo layout and patterns | `docs/mvp/REPO_STRUCTURE.md` |
| Environment variables | `docs/mvp/ENVIRONMENT.md` |

## Tech stack

| Layer | Technology |
|---|---|
| Frontend | Next.js 14 (App Router), TypeScript, pnpm |
| Backend | FastAPI (Python 3.11+), SQLAlchemy async, Alembic |
| Database | PostgreSQL 16 + pgvector on AWS RDS (`ap-south-1`) |
| Auth | Supabase Auth (JWT, Google OAuth) |
| File storage | AWS S3 (`ap-south-1`), direct client upload via pre-signed URL |
| Queue | AWS SQS (standard queues + DLQs) |
| AI | Claude API (`claude-sonnet-4-20250514`) |
| Embeddings | Cohere `embed-multilingual-v3` |
| OCR | AWS Textract |
| Cache | Redis (sessions + rate limits only — no PHI) |
| Monorepo | Turborepo |
| IaC | Terraform |

## Conventions

### Python (FastAPI services)
- Async everywhere — use `async def` for all route handlers and service methods
- Pydantic v2 for all request/response models
- SQLAlchemy async session via dependency injection
- Service layer functions never import from routers
- All config via `config.py` (pydantic-settings) — never `os.environ` directly

### TypeScript (Next.js)
- App Router only — no Pages Router patterns
- Server Components by default; `"use client"` only when needed for interactivity
- Typed API client in `lib/api.ts` — never raw `fetch` in components
- All API calls go through Next.js route handlers (thin proxy to FastAPI)

### Database
- All migrations via Alembic — never alter tables manually
- New columns always nullable or with a default — never block existing rows
- RLS policy required for any table containing user data — verify after every migration
- Test cross-user data access after every schema change

### Git
- Branch naming: `feat/`, `fix/`, `chore/`
- Commit messages: conventional commits (`feat:`, `fix:`, `chore:`, `docs:`)
- No direct commits to `main` — PRs required

## Files you must not change without discussion

These files contain medically and legally sensitive content. Changes require explicit review.

| File | Why |
|---|---|
| `services/api/db/seeds/emergency_templates.py` | Emergency responses reviewed by a doctor |
| `services/api/services/orchestration/urgency.py` | Critical value thresholds — medical decision |
| `services/api/db/seeds/prompt_blocks.py` | Safety rules — changing these affects all users |
| `services/api/services/orchestration/safety.py` | Diagnosis detection + hard block patterns |
| `services/api/middleware/consent.py` | DPDP Act 2023 compliance logic |

## Hard rules (non-negotiable)

1. **PII tokenization wraps every call to Claude, Textract, and Cohere.** Never bypass `pii.py` middleware.
2. **No PHI in Redis.** Sessions and rate limit counters only.
3. **No PHI in logs.** Use `report_id` not report content in log messages.
4. **Audit log is append-only.** Never add UPDATE or DELETE permissions to the audit_log table.
5. **S3 objects are never public.** Always generate pre-signed URLs — never set object ACL to public.
6. **Emergency template bypasses Claude.** When `urgency == "emergency"`, serve the hardcoded template. Never route to Claude.
7. **RLS on all user tables.** Run `SELECT * FROM pg_policies` after every migration to verify.
8. **All resources in `ap-south-1`.** No cross-region operations on PHI.

## Running locally

```bash
# One-time setup
bash scripts/setup_local.sh

# Start all services
pnpm dev

# API only
cd services/api && uvicorn main:app --reload

# Worker only
cd workers/ingestion && python main.py

# Run RAG benchmark
python kb/scripts/benchmark.py --env local
```

## Environment variables

See `docs/mvp/ENVIRONMENT.md` for the full list.
Copy `.env.example` to `.env.local` and fill in values before running locally.
Never commit `.env.local` or any file containing real API keys.

## When you're unsure

1. Check `docs/` first — the answer is likely there
2. If it touches safety, PII, or urgency logic — flag for human review before implementing
3. If it changes the prompt or guardrails — read `docs/safety/PROMPT_ARCHITECTURE.md` fully first
