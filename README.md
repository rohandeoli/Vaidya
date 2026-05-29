# Medical AI Assistant — Architecture Documentation

> This documentation captures the complete system design for a medical AI assistant that helps users understand their health reports, lab results, and scans. It is intended to be the primary reference for engineers, Claude Code, and any AI-assisted implementation.

## Core product principle

This app helps users **understand** their health data — it never diagnoses, prescribes, or replaces a doctor. Every architectural decision flows from this constraint.

---

## Document index

| File | What it covers |
|---|---|
| [`architecture/SYSTEM_OVERVIEW.md`](architecture/SYSTEM_OVERVIEW.md) | Full system layers, tech stack, and component map |
| [`architecture/DATA_MODEL.md`](architecture/DATA_MODEL.md) | Database schema, FHIR structure, biomarker storage |
| [`architecture/SECURITY.md`](architecture/SECURITY.md) | Encryption, PII handling, compliance (DPDP / HIPAA) |
| [`rag/RAG_PIPELINE.md`](rag/RAG_PIPELINE.md) | Full retrieval pipeline: query expansion → reranking → injection |
| [`rag/CHUNK_SCHEMA.md`](rag/CHUNK_SCHEMA.md) | KB chunk JSON schema with all metadata fields |
| [`rag/CHUNKING_STRATEGY.md`](rag/CHUNKING_STRATEGY.md) | Per-document-type chunking rules |
| [`rag/KB_SOURCES.md`](rag/KB_SOURCES.md) | Knowledge base sources, update frequencies, India-specific notes |
| [`rag/KB_LIFECYCLE.md`](rag/KB_LIFECYCLE.md) | Editorial pipeline: ingestion → review → QA → promote → expire |
| [`safety/AI_ORCHESTRATION.md`](safety/AI_ORCHESTRATION.md) | Full request pipeline through the AI orchestration layer |
| [`safety/PROMPT_ARCHITECTURE.md`](safety/PROMPT_ARCHITECTURE.md) | Six-block prompt structure with versioning strategy |
| [`safety/GUARDRAILS.md`](safety/GUARDRAILS.md) | Safety rules: hard blocks, mandatory inclusions, tone rules |
| [`safety/URGENCY_MATRIX.md`](safety/URGENCY_MATRIX.md) | Four-tier urgency system and escalation logic |

---

## System layers at a glance

```
┌─────────────────────────────────────────────────┐
│  CLIENT LAYER                                   │
│  Mobile app (React Native / Flutter)            │
│  Web app (Next.js PWA)                          │
└────────────────────┬────────────────────────────┘
                     │ HTTPS / WSS
┌────────────────────▼────────────────────────────┐
│  EDGE LAYER                                     │
│  API Gateway (JWT auth, rate limiting)          │
│  CDN (static assets only — no PHI)              │
└────────────────────┬────────────────────────────┘
                     │ Internal network
┌────────────────────▼────────────────────────────┐
│  SERVICE LAYER                                  │
│  Doc ingestion · AI orchestration               │
│  User service · Report manager · Notifications  │
└────────────────────┬────────────────────────────┘
              ┌──────┴──────┐
┌─────────────▼───┐   ┌─────▼───────────────────┐
│  AI / ML LAYER  │   │  DATA LAYER             │
│  Claude API     │   │  PostgreSQL + pgvector  │
│  OCR engine     │   │  Object storage (S3)    │
│  Embeddings     │   │  Redis (no PHI)         │
│  RAG pipeline   │   │  Vector DB (pgvector)   │
└─────────────────┘   └─────────────────────────┘

  ── SECURITY & COMPLIANCE crosses all layers ──
  Encryption · Audit logs · PII masking · DPDP/HIPAA
```

---

## Key design principles for implementers

1. **PII never leaves your servers unmasked.** All user identifiers are tokenized before any call to Claude, OCR, or embeddings APIs. See [`safety/AI_ORCHESTRATION.md`](safety/AI_ORCHESTRATION.md).

2. **Emergency responses are hardcoded templates, not AI-generated.** If rule engine detects a critically abnormal value, bypass the LLM entirely. See [`safety/URGENCY_MATRIX.md`](safety/URGENCY_MATRIX.md).

3. **Prompts are versioned, composable blocks — not strings.** Each of the 6 prompt blocks is independently versioned and can be A/B tested or rolled back. See [`safety/PROMPT_ARCHITECTURE.md`](safety/PROMPT_ARCHITECTURE.md).

4. **Start with pgvector, not a separate vector DB.** Handles both dense and sparse (BM25) search. Migrate to Pinecone/Weaviate only when you hit scale limits. See [`rag/RAG_PIPELINE.md`](rag/RAG_PIPELINE.md).

5. **ICMR takes precedence over WHO for Indian users.** Reference ranges calibrated for the Indian population differ meaningfully from Western norms. See [`rag/KB_SOURCES.md`](rag/KB_SOURCES.md).

6. **No automated ingestion of medical content.** Every KB chunk requires a qualified medical reviewer to approve it. See [`rag/KB_LIFECYCLE.md`](rag/KB_LIFECYCLE.md).

7. **FHIR-compliant schema from day one.** Enables future ABDM integration without a painful migration. See [`architecture/DATA_MODEL.md`](architecture/DATA_MODEL.md).
