# Chunking strategy

Different document types require different chunking approaches. One-size-fits-all chunking (e.g. fixed 512-token windows) degrades retrieval quality significantly for medical content.

## Decision table

| Document type | Strategy | Target chunk size | Overlap |
|---|---|---|---|
| Reference range tables | One row = one chunk | 50–100 tokens | None |
| Explanatory guidelines | Semantic paragraphs | 150–300 tokens | 20 tokens |
| Patient education | Q&A pairs | 100–200 tokens | None |
| PubMed abstracts | Abstract-level only | 200–400 tokens | None |
| Screening protocols | One recommendation = one chunk | 100–200 tokens | None |

---

## Strategy 1: Reference range tables

Used for: lab manual appendices, guideline reference range sections, NABL lab normal value tables.

Rule: **One row = one chunk.** Never bundle multiple tests into one chunk.

Reason: Retrieval needs to find the exact test. A chunk containing 20 reference ranges will score medium relevance for all 20 queries and high relevance for none.

Required chunk structure:
```
[Test name] — Normal: [low]–[high] [unit] — [population group] — [source] [year]
```

Example:
```
HbA1c — Normal: 4.0–5.6% — Indian adult population (18+, all sexes) — ICMR 2023
```

The `content.values` structured fields must be populated from the numeric values in the row. This is what enables hallucination checking.

Demographic stratification: if a table has separate rows for male/female or age groups, each row is a separate chunk with the appropriate `sex` and `age_range` metadata.

---

## Strategy 2: Explanatory guidelines (semantic paragraphs)

Used for: WHO clinical guidelines, ICMR management guidelines, AIIMS protocols — the narrative sections, not the tables.

Rules:
- Chunk at natural paragraph boundaries. Never split mid-sentence.
- Target: 150–300 tokens per chunk.
- Apply 20-token overlap between adjacent chunks. This preserves context at chunk boundaries — a sentence that spans two chunks won't lose its context in retrieval.
- **Prepend the section heading** to every chunk. A chunk retrieved in isolation must be self-contained.

Example:

Source text:
```
Section: HbA1c Monitoring in Diabetes Management

For patients with stable glycaemic control, HbA1c testing is 
recommended every 6 months. For patients whose regimen has 
changed or who are not meeting glycaemic targets, testing 
every 3 months is recommended.

The relationship between HbA1c and mean plasma glucose is 
well established. An HbA1c of 7% corresponds to a mean 
plasma glucose of approximately 154 mg/dL.
```

Chunked as two chunks:
```
Chunk 1:
"HbA1c monitoring in diabetes management: For patients with stable 
glycaemic control, HbA1c testing is recommended every 6 months. For 
patients whose regimen has changed or who are not meeting glycaemic 
targets, testing every 3 months is recommended."

Chunk 2 (with 20-token overlap from previous):
"HbA1c monitoring in diabetes management: ...every 3 months is 
recommended. The relationship between HbA1c and mean plasma glucose 
is well established. An HbA1c of 7% corresponds to a mean plasma 
glucose of approximately 154 mg/dL."
```

---

## Strategy 3: Patient education Q&A pairs

Used for: all content in the patient education source category.

Rule: Each Q&A pair is one chunk. Never split a question from its answer. Never bundle multiple Q&As.

Format requirement:
```
Q: [question as a user would phrase it]
A: [plain-language answer, 2–5 sentences]
```

The Q component must use natural user language — not clinical terminology. This is what drives retrieval quality: the user's conversational query closely matches the Q form.

Multi-language rule: each Q&A pair has three parallel chunks — English, Hindi, Tamil — with the same base `chunk_id` plus a `_en`, `_hi`, `_ta` suffix. The RAG pipeline selects the appropriate language variant at retrieval time based on the user's language preference.

---

## Strategy 4: PubMed abstracts

Used for: curated research summaries from India-cohort studies.

Rule: One chunk per abstract. Include: title, authors (abbreviated), journal, year, abstract text.

Do not include: methods section in detail, full results tables, statistical appendices. Abstract + conclusion only.

Mandatory metadata fields for PubMed chunks:
- `content.evidence_level`: `rct`, `meta_analysis`, or `observational_large`
- `content.condition`: primary condition studied
- `content.biomarkers`: biomarkers investigated

Usage constraint: PubMed chunks are never used to support specific reference range values. They are used only for contextual "why this matters" educational content. The retrieval reranker is configured to deprioritise PubMed chunks when the query is a reference range lookup.

---

## Strategy 5: Screening protocols

Used for: MoHFW Ayushman Bharat screening guidelines, AIIMS preventive care protocols.

Rule: One recommendation = one chunk. Each chunk should answer a specific screening question: "who should be screened for X", "how often should Y be tested", "what is the screening test for Z".

Example:
```
Diabetes screening recommendation (ICMR 2023): Adults aged 30 and 
above with any one risk factor (family history of diabetes, 
overweight/obesity, history of gestational diabetes, or hypertension) 
should be screened for diabetes using fasting plasma glucose or HbA1c 
every 3 years. Asymptomatic adults over 45 without risk factors: 
screen every 5 years.
```

---

## Common chunking mistakes to avoid

1. **Fixed-token windows that ignore sentence boundaries.** Never cut mid-sentence. Always end at a period or natural paragraph break.

2. **Bundling multiple tests in one reference range chunk.** Kills retrieval precision — each test must be its own chunk.

3. **Missing section headings.** A chunk without its heading is orphaned when retrieved — the reader (Claude) has no context for what section of what guideline this came from.

4. **Inconsistent biomarker naming in the `content.biomarkers` array.** If a chunk says `["HbA1c"]` but a user query uses "A1C", the structured filter won't match. Always include all common abbreviations and synonyms.

5. **Not populating `content.values` for reference range chunks.** This breaks hallucination checking. Every reference range chunk must have structured numeric values.

6. **Chunks that are too long.** A 600-token chunk will exhaust a significant portion of the 900-token RAG budget with a single chunk. If a passage is longer than 300 tokens, it should be two chunks with overlap.
