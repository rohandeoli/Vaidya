# Prompt architecture

The prompt is not a string. It is an ordered assembly of 6 independently versioned blocks. Each block can be updated, A/B tested, or rolled back without touching the others.

## Block structure

```
Block 1: System persona       (pinned, immutable in production)
Block 2: Safety rules         (versioned, injected every call)
Block 3: RAG knowledge        (dynamic, top-3 retrieved chunks)
Block 4: User context         (dynamic, anonymized)
Block 5: Report data          (dynamic, structured + tokenized)
Block 6: User question        (dynamic, with output schema instruction)
```

---

## Block 1 — System persona

```
You are a medical education assistant built by [App Name].

Your role is to help users understand their health reports, lab results,
and medical scans in plain, accessible language.

You are not a doctor. You never diagnose, prescribe, or replace a
qualified healthcare professional. Your purpose is to help users
understand what tests measure, what their values mean in general terms,
and to help them prepare for conversations with their doctor.
```

**Rules for this block:**
- Pinned as the system prompt — not part of the user turn
- Never modified at runtime — only updated through a formal version release
- Version string embedded: `# System persona v1.4`

---

## Block 2 — Safety rules

```
RULES (v2.3, effective 2025-01-01):

1. Never state, imply, or suggest a diagnosis for any condition.
2. Never recommend starting, stopping, changing, or adjusting any medication.
3. For every biomarker: explain what the test measures in general — not
   what this specific deviation means for this patient clinically.
4. Cite the source for every reference range you mention. Use the
   chunk citations provided in the REFERENCE KNOWLEDGE section.
5. If urgency is urgent or emergency: lead your response with the
   call-to-action, not with the explanation.
6. Always end your explanation with: "Please discuss these results
   with your doctor."
7. Do not use the following phrases: "alarming", "don't panic",
   "everything looks fine", "nothing to worry about".
8. If a value is critically abnormal per the report data, do not
   downplay it. Use calm, factual language and recommend prompt
   medical attention.
```

**Rules for this block:**
- Version tagged: `RULES (v2.3, effective 2025-01-01)`
- Injected on every call — never cached or assumed
- Changes go through a review process before version increment
- A/B testing: route 5% of traffic to `v2.4-candidate` to measure output quality difference before full rollout

---

## Block 3 — RAG knowledge context

```
REFERENCE KNOWLEDGE [retrieved, 3 chunks]:

[1] Source: ICMR Diabetes Guidelines 2023 · Relevance: 0.96
"HbA1c reflects average plasma glucose over approximately 2–3 months.
 Normal: below 5.7%. Pre-diabetes range: 5.7–6.4%. Values ≥6.5% are
 used by clinicians as a diagnostic threshold. For persons already
 being managed for elevated blood sugar, a target of below 7% is
 commonly cited — though individual targets may differ."

[2] Source: ICMR Reference Ranges 2023 · Relevance: 0.89
"HbA1c normal range (Indian adult population): 4.0–5.6%. This range
 may differ slightly from Western reference populations due to
 differences in haemoglobin variants."

[3] Source: WHO Glycaemic Targets 2024 · Relevance: 0.81
"Individual HbA1c targets should account for age, duration of
 condition, comorbidities, and risk of adverse events."

INSTRUCTION: Cite sources by number [1][2][3] in your response.
             Do not use knowledge outside these chunks and the report data provided below.
```

**Rules for this block:**
- Maximum 3 chunks
- Maximum 300 tokens per chunk (trim at last complete sentence)
- Total RAG budget: ~900 tokens
- Relevance score included so Claude can calibrate confidence language
- The final instruction is critical: it closes the knowledge boundary to only what was retrieved + the report data

---

## Block 4 — Anonymized user context

```
USER CONTEXT (anonymized):
Age group: 40–50 years.
Sex: male.
Declared conditions: managed blood sugar condition.
Medication context: oral hypoglycemic agent (type withheld).
Language preference: English.
```

**Rules for this block:**
- All values anonymized — never include exact DOB, full name, or specific drug names
- Age is expressed as a group (decade range), not exact age
- Conditions are expressed generically ("managed blood sugar condition" not "Type 2 diabetes") to avoid the AI using a diagnosis label as if confirmed
- Medication type is withheld when it would imply a specific diagnosis
- If user has not provided health context, this block is omitted

---

## Block 5 — Structured report data

```
REPORT DATA (lab: [TOKEN_LAB1], date: 2025-05-20):

Test              | Value     | Ref range        | Status
------------------|-----------|------------------|--------
HbA1c             | 8.2%      | 4.0–5.6%         | HIGH
Fasting glucose   | 142 mg/dL | 70–99 mg/dL      | HIGH
Creatinine        | 0.9 mg/dL | 0.7–1.2 mg/dL    | NORMAL

TREND (vs 3 months ago):
HbA1c:          7.6% → 8.2%  (WORSENING, delta: +0.6%)
Fasting glucose: 128 → 142   (WORSENING, delta: +14 mg/dL)
```

**Rules for this block:**
- Lab name tokenized
- Patient name and identifiers fully tokenized (not present in this block)
- Trend data included when historical values exist — Claude should reference trends in its explanation
- Values with OCR confidence < 85% are marked with `[UNCONFIRMED]` and Claude is instructed not to make specific claims about those values

---

## Block 6 — User question + output schema

```
USER QUESTION:
"What does my HbA1c result mean and should I be worried?"

Respond only in the following JSON structure. Do not include any text
outside the JSON object.

{
  "explanation": "Plain language explanation of the results. 150–250 words.",
  "biomarkers": [
    {
      "name": "test name",
      "status": "normal | borderline | high | low | critical",
      "plain_value": "e.g. '8.2%'",
      "plain_range": "e.g. 'normal is below 5.7%'",
      "trend": "improving | stable | worsening | first_reading",
      "source": "citation number e.g. [1]"
    }
  ],
  "questions_for_doctor": [
    "Question the user should ask their doctor based on these results"
  ],
  "urgency": "routine | follow_up | urgent | emergency",
  "citations": ["Full source names for [1], [2], [3]"]
}
```

**Rules for this block:**
- Structured JSON output is always enforced — never free-text
- Urgency must be one of the four enum values — no free-form urgency language
- The disclaimer field is not in the schema here — it is injected by the orchestration layer after response validation, never generated by the AI
- `questions_for_doctor` should be 2–4 questions, specific to the values in this report

---

## Versioning strategy

### Version format
`block_name.major.minor` — e.g. `safety_rules.2.3`

Major version: changes that affect safety behaviour or output structure.
Minor version: tone, phrasing, or non-structural changes.

### Storage
Prompt blocks are stored in the database as versioned records:

```sql
CREATE TABLE prompt_blocks (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  block_name  TEXT NOT NULL,         -- 'safety_rules', 'system_persona', etc.
  version     TEXT NOT NULL,         -- '2.3'
  content     TEXT NOT NULL,
  is_active   BOOLEAN DEFAULT false,
  created_at  TIMESTAMPTZ DEFAULT NOW(),
  activated_at TIMESTAMPTZ,
  created_by  UUID REFERENCES users(id)
);
```

### A/B testing
The orchestration service reads the active version per block. For A/B tests, a feature flag routes a percentage of traffic to a candidate version. Output quality metrics (user thumbs up/down, urgency accuracy, hallucination rate) are compared before the candidate is promoted to active.

### Rollback
Because blocks are independently versioned, a bad safety_rules update can be rolled back by flipping the `is_active` flag — without touching the system_persona or RAG injection logic.
