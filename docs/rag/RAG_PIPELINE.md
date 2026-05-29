# RAG pipeline

The RAG pipeline retrieves relevant knowledge base chunks before every AI call, grounding Claude's responses in authoritative medical sources and dramatically reducing hallucination of reference ranges.

## Pipeline overview

```
User query + report data
         │
         ▼
┌─────────────────────┐
│ 1. Query analysis   │  Extract biomarkers, expand synonyms,
│    & expansion      │  generate structured search terms
└────────┬────────────┘
         │
    ┌────┴──────────────────────────────┐
    │                                   │
    ▼                                   ▼
┌─────────────────┐           ┌─────────────────┐
│ 2. Dense search │           │ 3. Sparse search │
│    (semantic)   │           │    (BM25)        │
│    top-20       │           │    top-20        │
└────────┬────────┘           └────────┬─────────┘
         │                             │
         └──────────────┬──────────────┘
                        ▼
               ┌─────────────────┐
               │ 4. RRF fusion   │  Merge ranked lists
               │                 │  into single ranking
               └────────┬────────┘
                        ▼
               ┌─────────────────┐
               │ 5. Cross-encoder│  Rerank top-10 with
               │    reranking    │  full query context
               └────────┬────────┘
                        ▼
               ┌─────────────────┐
               │ 6. Filter &     │  Dedup, freshness,
               │    dedup        │  token budget
               └────────┬────────┘
                        ▼
               ┌─────────────────┐
               │ 7. Inject into  │  Block 3 of prompt
               │    prompt       │  with citation tags
               └─────────────────┘
```

---

## Stage 1: Query analysis & expansion

Before any search, a small fast model (Claude Haiku) extracts medical concepts and generates synonyms.

Input: raw user query + structured biomarker data from the report

Output:
```json
{
  "primary_query": "HbA1c reference range interpretation",
  "secondary_queries": [
    "glycated haemoglobin normal values",
    "blood glucose 3-month average test"
  ],
  "biomarker_filters": ["HbA1c", "glycated haemoglobin", "A1C"],
  "condition_context": "diabetes",
  "guideline_preference": "ICMR"
}
```

Why this matters: Users type "sugar test" but the KB is indexed under "fasting plasma glucose". Without expansion, no match. Lab reports from different hospitals use different abbreviations for the same test — expansion handles this.

Latency target: < 200ms (Haiku call)

---

## Stage 2: Dense retrieval (semantic search)

Uses vector similarity search against pre-computed chunk embeddings.

```python
# Embed the expanded query
query_embedding = cohere.embed(
    texts=[primary_query + " " + " ".join(secondary_queries)],
    model="embed-multilingual-v3",
    input_type="search_query"
)

# ANN search in pgvector
results = db.execute("""
    SELECT chunk_id, text, metadata,
           1 - (embedding <=> %s) AS cosine_similarity
    FROM kb_chunks
    WHERE metadata->>'region' IN ('IN', 'GLOBAL')
      AND metadata->>'review_status' = 'approved'
      AND (expires_at IS NULL OR expires_at > NOW())
    ORDER BY embedding <=> %s
    LIMIT 20
""", [query_embedding, query_embedding])
```

Embedding model: Cohere `embed-multilingual-v3`
Reason: Single model supports English, Hindi, and Tamil — critical for Indian language support without maintaining separate indexes.

Index type: HNSW (hierarchical navigable small world) — better recall than IVFFlat at moderate dataset sizes.

Latency target: < 30ms

---

## Stage 3: Sparse retrieval (BM25)

Runs in parallel with dense retrieval. Uses PostgreSQL full-text search.

```sql
SELECT chunk_id, text, metadata,
       ts_rank(tsv, query) AS bm25_score
FROM kb_chunks,
     to_tsquery('english',
       'HbA1c | "glycated haemoglobin" | "A1C" | "HbA1c reference"'
     ) query
WHERE tsv @@ query
  AND metadata->>'review_status' = 'approved'
  AND (expires_at IS NULL OR expires_at > NOW())
ORDER BY bm25_score DESC
LIMIT 20;
```

Why BM25 alongside dense:
- Dense search misses exact numeric values — "8.2%" does not semantically match "greater than 8.0% requires review"
- Medical abbreviations (INR, eGFR, TSH, ALT) are single tokens — BM25 retrieves them precisely
- Drug names, lab codes, ICD terms — exact string match outperforms semantic similarity

No separate search engine needed — pgvector + PostgreSQL tsvector handles both in one database.

Latency target: < 20ms

---

## Stage 4: Reciprocal Rank Fusion (RRF)

Merges the dense and sparse result lists into a single unified ranking.

```python
def rrf_score(rank: int, k: int = 60) -> float:
    return 1.0 / (k + rank)

def merge_with_rrf(dense_results, sparse_results):
    scores = {}
    
    for rank, chunk in enumerate(dense_results, start=1):
        scores[chunk.id] = scores.get(chunk.id, 0) + rrf_score(rank)
    
    for rank, chunk in enumerate(sparse_results, start=1):
        scores[chunk.id] = scores.get(chunk.id, 0) + rrf_score(rank)
    
    return sorted(scores.items(), key=lambda x: x[1], reverse=True)
```

Why RRF:
- Works on ranks, not raw scores — dense cosine similarity (0.0–1.0) and BM25 TF-IDF scores live on different scales
- No normalisation needed
- k=60 is the standard value; decreasing k gives more weight to top-ranked results, increasing k flattens the distribution

Output: unified ranked list of ~30 candidates (duplicates across dense and sparse now scored by both)

Latency: < 5ms (pure Python computation)

---

## Stage 5: Cross-encoder reranking

Takes the top-10 from RRF and re-scores them with full query context.

```python
results = cohere.rerank(
    query=f"{primary_query}. Context: {biomarker_value} {biomarker_unit}",
    documents=[chunk.text for chunk in top_10_chunks],
    model="rerank-multilingual-v3",
    top_n=5
)
```

Why reranking:
- Bi-encoder (dense) embeds query and chunk separately — cannot model their interaction
- Cross-encoder sees the full (query + chunk) pair — much more accurate relevance scoring
- Too slow to run on the full KB; two-stage approach is the industry standard
- Multilingual model handles mixed-language content (English guidelines + Hindi patient education)

Latency target: < 150ms

---

## Stage 6: Filtering & deduplication

Clean the top-5 reranked chunks before injection.

### Deduplication
Remove near-duplicate chunks (cosine similarity > 0.95 between any two candidates). Keep the higher-ranked version. If multiple chunks from the same source cover the same topic, keep only the top-scoring one.

### Freshness filter
If two chunks from different guideline years cover the same biomarker and topic, prefer the newer one. Medical guidelines update; old reference ranges can be wrong.

Tie-breaking uses the `guideline_year` metadata field.

### Token budget
- Maximum 3 chunks injected into the prompt
- Each chunk capped at 300 tokens (trim at last complete sentence before limit)
- Total RAG context budget: ~900 tokens
- This leaves ~2,600 tokens for system prompt, user context, report data, and user question in a 4,096-token window

---

## Stage 7: Context injection & citation tagging

Inject the final chunks into Block 3 of the prompt with structured attribution.

```
REFERENCE KNOWLEDGE [retrieved, 3 chunks]:

[1] Source: {chunk.source.name} {chunk.source.publication_date.year}
    Relevance: {rerank_score:.2f}
    "{chunk.text}"

[2] Source: ...
    Relevance: ...
    "..."

[3] Source: ...

INSTRUCTION: Cite sources by number [1][2][3] in your response.
             Do not use knowledge outside these chunks and the report data.
```

Citation mapping is stored alongside the response so the UI can render "[1]" as a tappable link to the source document.

---

## End-to-end latency budget

| Stage | Latency |
|---|---|
| Query expansion (Haiku) | ~200ms |
| Dense retrieval (pgvector ANN) | ~30ms |
| BM25 retrieval (Postgres) | ~20ms |
| RRF merge | ~5ms |
| Cross-encoder rerank | ~150ms |
| Dedup + filter + inject | ~5ms |
| **Total RAG overhead** | **~410ms** |

After RAG completes, Claude streaming begins. First tokens typically arrive within 1–2 seconds of the user submitting their query.

Dense retrieval and BM25 retrieval run in parallel — the actual wall-clock time for stages 2+3 is max(30ms, 20ms) = 30ms, not 50ms.
