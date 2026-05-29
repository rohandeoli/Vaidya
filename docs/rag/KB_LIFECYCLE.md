# Knowledge base lifecycle

The KB requires a full editorial pipeline. A static KB is a liability in medicine — guidelines update, errors are discovered, new research changes recommendations.

## Lifecycle stages

```
Source monitoring
       │
       ▼
Medical reviewer triage  ←── Changes rejected here
       │
       ▼
Chunking & embedding
       │
       ▼
QA retrieval test  ←── Must pass before promotion
       │
       ▼
Promote to production
       │
       ▼
Monitor & expiry
       │
       ▼
Deprecate / replace
```

---

## Stage 1: Source monitoring

Automated weekly scan of primary sources for new or updated content:

- ICMR website (icmr.gov.in) — guidelines section
- MoHFW publications portal
- WHO publications (filtered by topic tags: diabetes, anaemia, cardiovascular, kidney, liver, thyroid)
- AIIMS clinical protocols page
- PubMed RSS feeds (search: India cohort + target biomarkers)

On detection of new or updated content: create a review ticket and assign to the medical reviewer queue.

Tools: scheduled Lambda or Cloud Run job, RSS feed monitoring, web scraping with change detection.

---

## Stage 2: Medical reviewer triage

**This is a mandatory human gate. No automated ingestion of new medical content.**

A qualified reviewer (MBBS or equivalent with clinical experience) evaluates each flagged item:

Reviewer decisions:
- **Ingest as-is**: content is clear, authoritative, and within scope
- **Ingest with edits**: content requires plain-language rewriting or scope narrowing
- **Reject**: out of scope, duplicate, insufficient authority, or potentially misleading

The reviewer also sets:
- `quality.confidence` score (0.0–1.0)
- `content.values` structured numeric fields (reference ranges)
- `source.evidence_level` for PubMed content
- `expires_at` date (default: publication date + 2 years)

Reviewer dashboard requirements:
- Side-by-side view of existing chunks and proposed new/updated chunks for the same biomarker
- Diff view when updating an existing chunk
- One-click approve with pre-filled metadata
- Mandatory free-text comment field explaining the approval decision

---

## Stage 3: Chunking & embedding

After reviewer approval, automated pipeline runs:

1. Apply chunking strategy (see [`CHUNKING_STRATEGY.md`](CHUNKING_STRATEGY.md))
2. Generate embeddings with Cohere embed-multilingual-v3
3. Populate `content.values` from reviewer-provided structured data
4. Set `quality.review_status = 'draft'`
5. Write to draft KB index — not the live index

Draft index is a separate namespace in pgvector. Live queries never touch draft.

---

## Stage 4: QA retrieval test

Before promotion, the draft chunks must pass a benchmark test suite.

Test suite: 50 benchmark queries with expected top-3 chunk IDs.

Pass criteria:
- New/updated chunks appear in top-3 for all relevant benchmark queries
- No existing benchmark queries have their top-1 result degraded by the new chunks (regression check)
- No new chunks appear in top-3 for clearly unrelated queries (false positive check)

On failure: return to reviewer with test results. Reviewer may update chunk text or metadata and re-trigger.

---

## Stage 5: Promote to production

On test pass:

1. Move chunks from draft namespace to live namespace in pgvector
2. Mark any superseded chunks as `review_status = 'deprecated'` (do not delete)
3. Deprecated chunks remain queryable for audit purposes but are excluded from retrieval by the `review_status = 'approved'` filter
4. Create a KB release record in the audit log: what changed, who approved, when

Promotion is a gated deploy — requires sign-off from both the medical reviewer and an engineering lead.

---

## Stage 6: Expiry & deprecation

Every chunk has an `expires_at` field. Default: publication date + 24 months.

30 days before expiry: alert sent to medical review team for each expiring chunk.

On expiry:
- Chunk is automatically excluded from retrieval (filtered by `expires_at > NOW()`)
- Does not delete — kept for audit trail
- Review team evaluates: re-approve with updated expiry, replace with newer guidance, or permanently deprecate

Medical guidelines older than 5 years without renewal are automatically deprecated regardless of `expires_at`.

---

## Emergency update process

When a major guideline change requires immediate KB update (e.g. ICMR revises a reference range):

1. Medical reviewer flags as **Priority: Emergency**
2. Chunking and embedding run within 2 hours
3. QA test suite runs automatically (no manual trigger needed)
4. On pass: immediate promotion without waiting for scheduled deploy window
5. Old chunks deprecated simultaneously

The emergency update process bypasses the standard weekly review schedule but does not bypass the human reviewer gate.
