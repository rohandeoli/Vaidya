# Data model

## Design principles

1. **FHIR R4 compatible from day one.** Schema is designed to map cleanly to FHIR resources. This enables future ABDM (Ayushman Bharat Digital Mission) integration without a painful migration.
2. **Biomarker history computed on write, not read.** Trend queries against years of data are instant because aggregates are pre-computed.
3. **Row-level security on all user data.** An application account can only read its own user's records — enforced at the database level, not just the application layer.

---

## Core tables

### users

```sql
CREATE TABLE users (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email             TEXT UNIQUE NOT NULL,
  phone             TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_active_at    TIMESTAMPTZ,

  -- Encrypted fields (pgcrypto)
  health_context    BYTEA,        -- age_group, sex, conditions, medications
  language_pref     TEXT DEFAULT 'en',

  -- Auth
  auth_provider     TEXT,         -- 'google', 'apple', 'email'
  auth_provider_id  TEXT,

  -- Soft delete
  deleted_at        TIMESTAMPTZ,
  deletion_scheduled_at TIMESTAMPTZ
);

-- Row-level security
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
CREATE POLICY users_own_row ON users
  USING (id = current_setting('app.current_user_id')::UUID);
```

### reports

```sql
CREATE TABLE reports (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID NOT NULL REFERENCES users(id),
  uploaded_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  report_date     DATE,
  lab_name        TEXT,
  report_type     TEXT,          -- 'blood_panel', 'lipid_profile', 'thyroid', 'scan', 'other'
  file_key        TEXT,          -- S3/GCS object key (not URL — URL generated on demand)
  file_hash       TEXT,          -- SHA-256 of original file (for integrity)
  ocr_status      TEXT DEFAULT 'pending',  -- 'pending', 'complete', 'failed', 'manual_review'

  -- FHIR mapping
  fhir_bundle     JSONB,         -- Full FHIR DiagnosticReport bundle

  -- Parsed output
  raw_extracted   BYTEA,         -- Encrypted extracted text + OCR output
  parse_confidence FLOAT,        -- Minimum OCR confidence across all fields

  deleted_at      TIMESTAMPTZ
);

ALTER TABLE reports ENABLE ROW LEVEL SECURITY;
CREATE POLICY reports_own_row ON reports
  USING (user_id = current_setting('app.current_user_id')::UUID);
```

### biomarker_values

```sql
CREATE TABLE biomarker_values (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  report_id       UUID NOT NULL REFERENCES reports(id),
  user_id         UUID NOT NULL REFERENCES users(id),
  test_name       TEXT NOT NULL,         -- Normalised name: 'HbA1c', 'Fasting glucose', etc.
  test_name_raw   TEXT,                  -- Original name from the report
  value_numeric   FLOAT,
  value_text      TEXT,                  -- For non-numeric results ('Positive', 'Negative')
  unit            TEXT,
  ref_range_low   FLOAT,
  ref_range_high  FLOAT,
  ref_range_text  TEXT,                  -- Original range text from the report
  status          TEXT,                  -- 'normal', 'borderline', 'high', 'low', 'critical'
  report_date     DATE NOT NULL,
  ocr_confidence  FLOAT,                 -- Confidence of this specific field

  -- FHIR mapping
  loinc_code      TEXT,                  -- LOINC code for the test
  snomed_code     TEXT
);

CREATE INDEX bv_user_test_date ON biomarker_values (user_id, test_name, report_date DESC);
CREATE INDEX bv_report ON biomarker_values (report_id);

ALTER TABLE biomarker_values ENABLE ROW LEVEL SECURITY;
CREATE POLICY bv_own_row ON biomarker_values
  USING (user_id = current_setting('app.current_user_id')::UUID);
```

### biomarker_trends

Pre-computed trend summaries — updated on every new report ingestion.

```sql
CREATE TABLE biomarker_trends (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID NOT NULL REFERENCES users(id),
  test_name       TEXT NOT NULL,
  latest_value    FLOAT,
  latest_date     DATE,
  previous_value  FLOAT,
  previous_date   DATE,
  trend_direction TEXT,          -- 'improving', 'stable', 'worsening', 'first_reading'
  trend_delta     FLOAT,         -- latest - previous
  trend_pct_change FLOAT,        -- percentage change
  reading_count   INTEGER,
  updated_at      TIMESTAMPTZ DEFAULT NOW(),

  UNIQUE (user_id, test_name)
);

ALTER TABLE biomarker_trends ENABLE ROW LEVEL SECURITY;
CREATE POLICY bt_own_row ON biomarker_trends
  USING (user_id = current_setting('app.current_user_id')::UUID);
```

### ai_sessions

```sql
CREATE TABLE ai_sessions (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID NOT NULL REFERENCES users(id),
  report_id       UUID REFERENCES reports(id),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_active_at  TIMESTAMPTZ,

  -- Prompt metadata (for debugging and improvement)
  prompt_versions JSONB,         -- {"system_persona": "1.4", "safety_rules": "2.3", ...}
  model           TEXT,
  total_latency_ms INTEGER
);

CREATE TABLE ai_messages (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id      UUID NOT NULL REFERENCES ai_sessions(id),
  user_id         UUID NOT NULL REFERENCES users(id),
  role            TEXT NOT NULL,         -- 'user' or 'assistant'
  content         BYTEA NOT NULL,        -- Encrypted
  rag_chunks_used TEXT[],                -- chunk_ids retrieved for this message
  urgency         TEXT,                  -- The urgency value from AI output
  latency_ms      INTEGER,
  feedback        TEXT,                  -- 'positive', 'negative', null
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE ai_sessions ENABLE ROW LEVEL SECURITY;
CREATE POLICY sessions_own_row ON ai_sessions
  USING (user_id = current_setting('app.current_user_id')::UUID);
```

### audit_log

Append-only. No UPDATE or DELETE permitted for any application role.

```sql
CREATE TABLE audit_log (
  id              BIGSERIAL PRIMARY KEY,
  event_type      TEXT NOT NULL,
  user_id         UUID,
  resource_type   TEXT,
  resource_id     UUID,
  actor_id        UUID,
  actor_type      TEXT,          -- 'user', 'admin', 'system'
  ip_hash         TEXT,          -- SHA-256 of IP, not raw IP
  metadata        JSONB,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Only INSERT permitted for application roles
CREATE POLICY audit_insert_only ON audit_log
  FOR INSERT TO app_service WITH CHECK (true);
-- SELECT available only to admin roles
CREATE POLICY audit_admin_read ON audit_log
  FOR SELECT TO admin_role USING (true);
```

---

## FHIR R4 mapping

Key FHIR resources and how they map to this schema:

| FHIR Resource | Maps to |
|---|---|
| `Patient` | `users` table (id, demographics) |
| `DiagnosticReport` | `reports` table |
| `Observation` | `biomarker_values` rows |
| `Practitioner` | (future) ordering physician |
| `Organization` | Lab / hospital (stored in `reports.lab_name`) |

The `reports.fhir_bundle` JSONB column stores the full FHIR DiagnosticReport bundle for each report. This enables:
- Export to ABDM (Ayushman Bharat Digital Mission) in future
- HL7 FHIR R4 API endpoint for provider integrations
- Interoperability with hospital EMR systems

LOINC codes on `biomarker_values` enable standardised identification of tests across different lab naming conventions.

---

## Trend computation

Trends are computed by a background job triggered on every new report ingestion:

```python
def compute_trend(user_id: str, test_name: str) -> dict:
    # Get the two most recent readings for this test
    readings = db.execute("""
        SELECT value_numeric, report_date
        FROM biomarker_values
        WHERE user_id = %s AND test_name = %s
          AND value_numeric IS NOT NULL
          AND ocr_confidence > 0.85
        ORDER BY report_date DESC
        LIMIT 2
    """, [user_id, test_name])

    if len(readings) == 0:
        return None
    if len(readings) == 1:
        return {"trend_direction": "first_reading", "reading_count": 1}

    latest, previous = readings[0], readings[1]
    delta = latest.value_numeric - previous.value_numeric
    pct_change = (delta / previous.value_numeric) * 100 if previous.value_numeric != 0 else 0

    # Threshold for "stable" — within 5% change
    if abs(pct_change) <= 5:
        direction = "stable"
    elif delta > 0:
        direction = "worsening"  # Note: "worsening" assumes higher = worse
    else:
        direction = "improving"  # This is test-agnostic — some tests worsen when they go up, others when they go down

    return {
        "trend_direction": direction,
        "trend_delta": round(delta, 3),
        "trend_pct_change": round(pct_change, 1),
        "reading_count": len(readings)
    }
```

Note: "worsening" and "improving" in this schema are directional only — higher value = worsening. This is correct for glucose, HbA1c, creatinine, and most common biomarkers, but incorrect for haemoglobin (lower = worsening) and some others. The `test_name` → direction mapping must be stored in a configuration table, not hardcoded.
