# Chunk schema

Every document in the knowledge base is stored as one or more chunks. Each chunk carries a rich metadata envelope that powers retrieval, filtering, freshness ranking, source attribution, and hallucination checking.

## Full schema

```json
{
  "chunk_id": "icmr-diabetes-2023-hba1c-001",
  "text": "HbA1c below 5.7% is considered normal for the Indian adult population...",
  "embedding": [0.023, -0.147, 0.891],
  "tsv": "tsvector — managed by PostgreSQL",

  "source": {
    "name": "ICMR Diabetes Guidelines",
    "type": "national_guideline",
    "authority": "icmr",
    "url": "https://icmr.gov.in/guidelines/diabetes-2023",
    "publication_date": "2023-09-01",
    "version": "2023.2",
    "region": "IN"
  },

  "content": {
    "biomarkers": ["HbA1c", "glycated haemoglobin", "A1C"],
    "topic": "reference_range",
    "condition": "diabetes",
    "values": {
      "normal_low": 4.0,
      "normal_high": 5.6,
      "borderline_low": null,
      "borderline_high": 6.4,
      "unit": "%",
      "population": "indian_adult",
      "age_range": "18+",
      "sex": "all"
    }
  },

  "quality": {
    "review_status": "approved",
    "reviewed_by": "medical_reviewer_001",
    "reviewed_at": "2024-01-15T10:30:00Z",
    "confidence": 0.98
  },

  "embedding_model": "cohere-embed-multilingual-v3",
  "embedding_version": "3.1",
  "ingested_at": "2024-01-15T10:35:00Z",
  "expires_at": "2025-09-01T00:00:00Z",

  "lang": "en"
}
```

---

## Field reference

### Top-level fields

| Field | Type | Description |
|---|---|---|
| `chunk_id` | string | Human-readable ID: `{authority}-{topic}-{year}-{biomarker}-{seq}` |
| `text` | string | The chunk text as it will be injected into the prompt |
| `embedding` | float[] | Dense vector (1536-dim for Cohere embed-multilingual-v3) |
| `tsv` | tsvector | PostgreSQL full-text search index for BM25 |
| `lang` | string | ISO 639-1 language code: `en`, `hi`, `ta` |

### `source` object

| Field | Type | Enum values | Description |
|---|---|---|---|
| `name` | string | — | Display name for citations |
| `type` | string | `national_guideline`, `international_guideline`, `lab_reference`, `patient_education`, `research_abstract` | Source category |
| `authority` | string | `icmr`, `who`, `aiims`, `mohfw`, `nin`, `pubmed`, `lab_network` | Issuing authority |
| `url` | string | — | Source URL for citation links |
| `publication_date` | date | — | Used for freshness ranking |
| `version` | string | — | Guideline version string if applicable |
| `region` | string | `IN`, `GLOBAL`, `US`, `EU` | Geographic scope |

### `content` object

| Field | Type | Description |
|---|---|---|
| `biomarkers` | string[] | All biomarker names/abbreviations this chunk is relevant to. Used for structured pre-filtering before ANN search. |
| `topic` | string | `reference_range`, `explanation`, `lifestyle`, `screening_protocol`, `research_finding` |
| `condition` | string | Primary condition: `diabetes`, `anaemia`, `thyroid`, `cardiovascular`, `kidney`, `liver`, `general` |
| `values` | object | Structured numeric ranges for hallucination checking (see below) |

### `content.values` object

This is the most critical field for safety. Every reference range claim Claude makes is validated against this structured data.

| Field | Type | Description |
|---|---|---|
| `normal_low` | number or null | Lower bound of normal range |
| `normal_high` | number or null | Upper bound of normal range |
| `borderline_low` | number or null | Lower bound of borderline/pre-disease range |
| `borderline_high` | number or null | Upper bound of borderline range |
| `unit` | string | `%`, `mg/dL`, `g/dL`, `mEq/L`, `IU/L`, etc. |
| `population` | string | `indian_adult`, `indian_child`, `indian_elderly`, `global_adult` |
| `age_range` | string | e.g. `18-60`, `60+`, `0-18` |
| `sex` | string | `male`, `female`, `all` |

### `quality` object

| Field | Type | Description |
|---|---|---|
| `review_status` | string | `draft`, `approved`, `deprecated` |
| `reviewed_by` | string | Medical reviewer ID (foreign key to reviewers table) |
| `reviewed_at` | timestamp | When this chunk was approved |
| `confidence` | float | 0.0–1.0, set by reviewer. < 0.9 flagged in output. |

---

## PostgreSQL table definition

```sql
CREATE TABLE kb_chunks (
  chunk_id        TEXT PRIMARY KEY,
  text            TEXT NOT NULL,
  embedding       vector(1536) NOT NULL,
  tsv             TSVECTOR GENERATED ALWAYS AS (to_tsvector('english', text)) STORED,
  source          JSONB NOT NULL,
  content         JSONB NOT NULL,
  quality         JSONB NOT NULL,
  embedding_model TEXT NOT NULL,
  embedding_version TEXT NOT NULL,
  ingested_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at      TIMESTAMPTZ,
  lang            TEXT NOT NULL DEFAULT 'en',

  -- Only approved chunks are queryable
  CONSTRAINT approved_only CHECK (quality->>'review_status' = 'approved' OR quality->>'review_status' = 'draft')
);

-- Dense search index (HNSW for better recall)
CREATE INDEX kb_embedding_hnsw ON kb_chunks
  USING hnsw (embedding vector_cosine_ops)
  WITH (m = 16, ef_construction = 64);

-- Sparse search index
CREATE INDEX kb_tsv_idx ON kb_chunks USING GIN (tsv);

-- Metadata indexes for pre-filtering
CREATE INDEX kb_biomarkers_idx ON kb_chunks USING GIN ((content->'biomarkers'));
CREATE INDEX kb_region_idx ON kb_chunks ((source->>'region'));
CREATE INDEX kb_status_idx ON kb_chunks ((quality->>'review_status'));
CREATE INDEX kb_expires_idx ON kb_chunks (expires_at);
```

---

## Hallucination validation logic

When Claude cites a reference range, the orchestration service validates it:

```python
def validate_range_claim(
    biomarker: str,
    claimed_low: float | None,
    claimed_high: float | None,
    unit: str,
    retrieved_chunks: list[Chunk]
) -> bool:
    for chunk in retrieved_chunks:
        values = chunk.content.get("values", {})
        if (
            biomarker.lower() in [b.lower() for b in chunk.content.get("biomarkers", [])]
            and values.get("unit") == unit
        ):
            # Allow 5% tolerance for rounding differences
            tolerance = 0.05
            low_match = claimed_low is None or (
                values.get("normal_low") is None or
                abs(claimed_low - values["normal_low"]) / max(values["normal_low"], 0.01) <= tolerance
            )
            high_match = claimed_high is None or (
                values.get("normal_high") is None or
                abs(claimed_high - values["normal_high"]) / max(values["normal_high"], 0.01) <= tolerance
            )
            if low_match and high_match:
                return True
    return False  # No matching chunk found — flag as potential hallucination
```

If validation returns False, the specific claim is suppressed and replaced with: "The reference range for this test is shown on your report. Please refer to your report header or ask your doctor to clarify the normal values for your specific lab."
