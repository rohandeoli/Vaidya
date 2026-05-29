# MVP specification

## Decisions (locked)

| Decision | Choice | Rationale |
|---|---|---|
| Database | AWS RDS PostgreSQL 16 + pgvector | Data stays in `ap-south-1` (Mumbai) for DPDP compliance |
| Auth | Supabase Auth (JWT + OAuth) | Saves 2–3 weeks; RLS integrates with RDS via JWT claims |
| Backend | FastAPI (separate service) | Persistent connections, background workers, serves web + mobile later |
| File upload | Direct client → S3 (pre-signed URL) | Server never buffers file bytes; scales without change |
| AI streaming | SSE (Server-Sent Events) | Word-by-word render; dramatically better UX than polling |
| Monorepo tooling | Turborepo | No opinion on Python services; fast caching; simple setup |
| Message queue | AWS SQS (standard + FIFO) | Fully managed; zero ops overhead; already in AWS alongside Textract/S3 |
| Cloud region | AWS `ap-south-1` Mumbai | All PHI stays in India; DPDP Act 2023 compliance |
| Infra-as-code | Terraform | Reproducible environments; staging mirrors prod exactly |

---

## What ships in MVP

### Features

| Feature | Notes |
|---|---|
| Email + Google login | Via Supabase Auth |
| Report upload (web) | PDF + JPEG/PNG, direct to S3, max 10MB |
| OCR + structured extraction | AWS Textract, async via SQS, confidence flagging |
| PII tokenization | Before every external API call — non-negotiable |
| Basic RAG (dense only) | pgvector, top-3 chunks, ICMR + WHO starter KB (~500 chunks) |
| AI explanation engine | Claude Sonnet 4, 6-block prompt, full safety guardrails |
| Results screen (streaming) | SSE, explanation + biomarker cards + urgency banner + doctor questions |
| Urgency system | 4-tier rule engine + AI resolution, hardcoded emergency templates |
| Audit logging | Append-only, core events, from day one |
| Consent flow | Granular per-purpose (DPDP Act 2023 compliant) |
| Account deletion | Right to erasure, S3 lifecycle + DB soft delete |

### What is explicitly NOT in MVP

| Feature | When | Why deferred |
|---|---|---|
| Mobile app | V2 | Web covers the use case; mobile adds 6+ weeks |
| Report history / list view | V2 | Schema supports it; needs repeat users first |
| Trend charts | V2 | Needs 2+ reports; data is collected from day one |
| Health context profile | V2 | Don't gate first-use behind a form |
| Hindi / Tamil language | V2 | Validate English product first |
| Doctor visit PDF | V2 | High value, moderate effort |
| BM25 + reranker in RAG | V2 | Dense search sufficient for starter KB |
| Scan interpretation | V3 | Most medically sensitive feature |
| ABDM / FHIR integration | V3 | Schema is FHIR-ready; integration is a separate project |
| Push notifications | V3 | Requires mobile app |
| Family accounts | V3 | Needs RBAC extension |

---

## Extensibility hooks built into MVP

These are schema columns, stub functions, and interface slots that cost nothing now but unlock v2/v3 features without rearchitecting.

| Hook | Where | Unlocks |
|---|---|---|
| `biomarker_trends` table populated on every upload | DB + ingestion worker | Trend charts (v2) — data is there when UI ships |
| `fhir_bundle JSONB` column in `reports` | DB | ABDM integration (v3) |
| `health_context BYTEA` column in `users` | DB | Health context profile (v2) |
| `conversation history` table + session schema | DB | Multi-turn chat (v2) |
| `lang` field on KB chunks | DB | Hindi/Tamil KB (v2) |
| `language_pref` in user profile | DB | Localised AI responses (v2) |
| BM25 `tsvector` column on `kb_chunks` | DB | Hybrid RAG (v2) |
| `reranker()` pass-through in `retriever.py` | Code | Cohere reranker (v2) — swap in, same interface |
| HL7/FHIR parser stub in `parser.py` | Code | HL7 import (v2) |
| Mobile upload path in API design | API | React Native app (v2) |
| RBAC `user_roles` table | DB | Family accounts, provider view (v3) |
| `file_type` enum includes `scan` types | DB | Scan interpretation (v3) |

---

## Sprint plan (7 weeks)

### Sprint 1 — Foundation (Week 1–2)
Infrastructure, database, auth. No product features. Everything else builds on this.

**Deliverables:**
- RDS PostgreSQL in `ap-south-1` with pgvector extension
- All DB migrations run (full schema including v2/v3 columns — see above)
- RLS policies on all user-data tables, tested
- S3 bucket: AES-256 SSE, versioning on, public access blocked
- SQS queues: `ocr-jobs`, `extraction-jobs`, each with a dead letter queue
- Supabase Auth: email + Google OAuth, JWT, configured to use RDS
- FastAPI skeleton: `/health`, auth middleware, empty routers
- Next.js app: App Router, Supabase client, protected route layout
- Turborepo workspace configured: `apps/web`, `services/api`, `workers/ingestion`
- Terraform: staging environment in `ap-south-1`, all resources above

**Done when:** A logged-in user can reach a protected page. Auth tokens are validated. DB is reachable. S3 bucket exists. SQS queues exist.

---

### Sprint 2 — Upload & OCR (Week 2–3)

**Deliverables:**
- Pre-signed URL endpoint: `POST /reports/upload-url` → returns `{upload_url, report_id}`
- Client uploads directly to S3, then calls `POST /reports/{id}/confirm`
- Ingestion service: magic byte validation, ClamAV scan, EXIF strip
- SQS producer: enqueue OCR job after confirm
- Ingestion worker (SQS consumer): Textract call, confidence scoring per field
- Structured extractor: test name normalisation, ref range parsing, status (`normal/high/low/critical`)
- Low-confidence flag: fields < 85% stored as `unconfirmed`, surfaced in UI for user confirmation
- Persist to `reports` + `biomarker_values`
- Populate `biomarker_trends` stub (even if single reading)
- Upload UI: drag-and-drop, progress states (`uploading → processing → ready → error`)
- Processing poll: `GET /reports/{id}/status` with SSE push when ready

**Done when:** User uploads a real Indian blood report PDF and sees structured test values in the DB with confidence scores.

---

### Sprint 3 — RAG knowledge base (Week 3–4)

**Deliverables:**
- `kb/` pipeline: `chunker.py`, `embedder.py` (Cohere), `validator.py` (schema check)
- Starter KB ingested: ~500 chunks (top 20 blood panel tests — see `KB_SOURCES.md`)
- pgvector HNSW index on `kb_chunks.embedding`
- Dense retrieval function: `retrieve(query, top_k=3)` → ranked chunks with metadata
- BM25 `tsvector` column populated (not queried yet)
- Reranker pass-through: `rerank(query, chunks)` → returns chunks unchanged (interface locked)
- RAG benchmark test: 30 queries, pass rate > 90% top-3 accuracy
- `scripts/seed_kb.py` — idempotent, re-runnable

**Done when:** `retrieve("what is HbA1c normal range")` returns the correct ICMR 2023 chunk as top-1. Benchmark passes.

---

### Sprint 4 — AI orchestration & safety (Week 4–5)

**Deliverables:**
- PII tokenization middleware (wraps every outbound call to Claude, Textract, Cohere)
- Pre-send validator: aborts if raw PII detected in payload
- Prompt block system: `prompt_blocks` table, block assembly from DB, version tags
- Seed initial prompt blocks (all 6 blocks from `PROMPT_ARCHITECTURE.md`)
- Input safety classifier (Claude Haiku): block / flag / pass, < 80ms
- Claude API call: `claude-sonnet-4-20250514`, streaming, `temperature=0.2`, structured JSON schema
- Output validation: schema check, hallucination check (against `content.values`), diagnosis language scan
- Urgency rule engine: threshold table in DB, `max(rule_urgency, ai_urgency)` resolution
- Emergency template system: templates in DB (not code), reviewed before launch
- Audit log: every AI query logged with prompt version IDs + urgency + latency
- Consent check middleware: block AI queries if required consents not given

**Done when:** A tokenized report goes in, a validated structured JSON response comes out, and the urgency rule engine correctly flags a simulated critically abnormal value as `emergency`.

---

### Sprint 5 — Results UI + streaming (Week 5–6)

**Deliverables:**
- SSE endpoint: `GET /reports/{id}/explain?query=...` — streams Claude response
- Next.js streaming consumer: progressive render as tokens arrive
- Results screen components:
  - `<ExplanationStream>` — renders explanation text word-by-word
  - `<BiomarkerCard>` — status chip, value, range, source citation, trend slot (empty state)
  - `<UrgencyBanner>` — 4 tiers, correct visual weight, non-dismissible for urgent/emergency
  - `<DoctorQuestions>` — list with copy-to-clipboard
  - `<Citations>` — expandable source pills
  - `<Disclaimer>` — always visible, links to terms
- Processing state: spinner while OCR/extraction runs
- Low-confidence confirmation: inline prompt for unconfirmed fields before AI query
- Error states: OCR failed, AI unavailable, critically abnormal (emergency template)
- Mobile-responsive layout (web on phone browser as interim mobile solution)

**Done when:** User uploads a real report, sees streaming explanation, biomarker cards, and doctor questions. Emergency template fires correctly for critically abnormal simulated input.

---

### Sprint 6 — Consent, compliance & launch prep (Week 6–7)

**Deliverables:**
- Consent flow: 3 granular purposes, one DB record each, required before first AI query
- Consent withdrawal: accessible from settings, immediately blocks further AI queries
- Account deletion: S3 lifecycle tag, DB soft delete, scheduled hard delete at 30 days
- Privacy policy + terms of service (legal review required)
- Emergency templates reviewed and approved by a qualified doctor (before any real users)
- Critical value threshold table reviewed by a qualified doctor
- Security checklist:
  - RLS cross-user access test (automated)
  - PII tokenizer test (send real PII, verify it never appears in Claude logs)
  - Audit log append-only test (attempt UPDATE/DELETE, verify blocked)
  - Pre-signed URL TTL test (verify URL expires after 15 minutes)
- Load test: 50 concurrent uploads + AI queries on staging
- Staging deploy: full smoke test with 5 real Indian lab reports across different labs
- Runbook: on-call escalation, emergency template update process, incident response

**Done when:** A real user outside the team can sign up, upload a report, read the explanation, and delete their account. No PHI appears in any logs. Emergency flow tested end-to-end.

---

## Technical constraints (non-negotiable)

These constraints apply to every line of code written. Claude Code must respect these.

1. **PHI never leaves `ap-south-1`.** RDS, S3, SQS — all in Mumbai. No cross-region replication of raw data.
2. **PII tokenization wraps every outbound API call.** No exceptions. Pre-send validator enforces this.
3. **Emergency responses are hardcoded templates, not AI-generated.** When urgency = `emergency`, bypass Claude entirely.
4. **Prompt blocks are in the database, not in code.** They can be updated without a deployment.
5. **Audit log is append-only.** The application role has INSERT permission only. No UPDATE or DELETE.
6. **S3 objects are never public.** Always pre-signed URLs with 15-minute TTL.
7. **RLS on all user-data tables.** Cross-user data access must be impossible at the DB layer.
8. **No PHI in Redis.** Sessions and rate-limit counters only.
9. **OCR confidence < 85% = unconfirmed.** Never pass unconfirmed values to the AI without user verification.
10. **Urgency rule engine always runs.** It is independent of the AI's urgency assessment. `max(rule, ai)` wins.
