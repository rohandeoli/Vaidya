# AI orchestration pipeline

The AI orchestration service is the core of the application. Every user query flows through this pipeline before reaching Claude and before the response reaches the user.

## Pipeline overview

```
User query + uploaded file
         │
         ▼
┌─────────────────────┐
│ 1. Input intake     │  Parse file, OCR, extract structured data
│    & file parsing   │  Flag low-confidence extractions
└────────┬────────────┘
         ▼
┌─────────────────────┐
│ 2. PII stripping    │  Tokenize all identifiers before any external call
│    & tokenization   │  Token map stays server-side only
└────────┬────────────┘
         ▼
┌─────────────────────┐
│ 3. Context assembly │  Health context + history + RAG retrieval
└────────┬────────────┘
         ▼
┌─────────────────────┐
│ 4. Input safety     │  Fast classifier — block/flag/pass
│    classifier       │  ~80ms, runs before main LLM call
└────────┬────────────┘
         │
    ┌────┴──────────────┐
    │ BLOCKED?          │ → Return safe error message, log event
    └────────────────────┘
         │ PASS
         ▼
┌─────────────────────┐
│ 5. Prompt           │  Assemble 6-block versioned prompt
│    construction     │  See PROMPT_ARCHITECTURE.md
└────────┬────────────┘
         ▼
┌─────────────────────┐
│ 6. Claude API call  │  claude-sonnet-4-20250514, stream=true
│                     │  Structured JSON output schema enforced
└────────┬────────────┘
         ▼
┌─────────────────────┐
│ 7. Output           │  Schema validation, hallucination check,
│    validation       │  diagnosis detection, urgency override
└────────┬────────────┘
         │
    ┌────┴──────────────────────────────────┐
    │ urgency = emergency?                  │ → Serve hardcoded emergency template
    └────────────────────────────────────────┘
         │ NOT emergency
         ▼
┌─────────────────────┐
│ 8. De-tokenization  │  Restore original values from token map
│    & personalisation│  Apply language preference
│                     │  Inject mandatory disclaimer
└────────┬────────────┘
         ▼
┌─────────────────────┐
│ 9. Response         │  Stream to client, persist audit log,
│    delivery         │  collect feedback signal
└─────────────────────┘
```

---

## Stage 1: Input intake & file parsing

Accepted formats: PDF, JPEG, PNG, HL7 v2, FHIR JSON, plain text.

OCR routing:
- Digital PDFs with text layer → extract directly (no OCR needed)
- Scanned PDFs, JPEG, PNG → route to AWS Textract
- Textract table extraction handles complex lab report layouts

Confidence threshold: any field extracted with < 85% confidence is flagged and the user is prompted to confirm the value before AI processing begins. Never pass uncertain OCR output to the LLM.

Structured extraction output:

```json
{
  "tests": [
    {
      "name": "HbA1c",
      "value": 8.2,
      "unit": "%",
      "reference_low": 4.0,
      "reference_high": 5.6,
      "status": "HIGH",
      "ocr_confidence": 0.97
    }
  ],
  "report_date": "2025-05-20",
  "lab_name": "[TOKEN_LAB1]",
  "patient_name": "[TOKEN_A1B2]"
}
```

---

## Stage 2: PII stripping & tokenization

See [`../architecture/SECURITY.md`](../architecture/SECURITY.md) for full details.

Critical rule: **If the PII stripper fails or confidence is low, abort the request entirely. Never send potentially identifiable data to any external API.**

---

## Stage 3: Context assembly

Pull everything needed to build a rich, relevant prompt:

| Context type | Source | What is pulled |
|---|---|---|
| Health context | User service | Age group, sex, declared conditions, medication context, language preference |
| Biomarker history | Report manager | 3 most recent values for each biomarker in this report |
| Conversation history | Redis / DB | Last 5 exchanges from this session |
| RAG knowledge | RAG pipeline | Top-3 relevant KB chunks. See [`../rag/RAG_PIPELINE.md`](../rag/RAG_PIPELINE.md) |

---

## Stage 4: Input safety classifier

A small, fast model (Claude Haiku or fine-tuned classifier) that runs in < 80ms before the main LLM call.

### Block patterns
- "do I have [condition]" → diagnosis request
- "tell me what disease I have" → diagnosis request
- "ignore previous instructions" → prompt injection
- "stop taking [medication]" → prescriptive advice request
- "you are now a doctor" → persona override attempt

### Escalate to crisis flow (not normal AI path)
- Expressions of extreme distress
- Mentions of self-harm
- Queries about emergency symptoms combined with distress markers

### Pass
- Report explanation requests
- "what does X mean" biomarker questions
- Doctor visit preparation
- General wellness / lifestyle questions

### On block
1. Return a safe, helpful redirection message (not a cold error)
2. Log the event in audit log with query hash (not full content)
3. Do not make a Claude API call

---

## Stage 5: Prompt construction

See [`PROMPT_ARCHITECTURE.md`](PROMPT_ARCHITECTURE.md) for the full 6-block structure.

---

## Stage 6: Claude API configuration

```python
response = anthropic.messages.create(
    model="claude-sonnet-4-20250514",
    max_tokens=1200,
    temperature=0.2,     # Low = consistent, factual tone
    stream=True,
    system=assembled_system_prompt,
    messages=[
        {"role": "user", "content": user_message}
    ]
)
```

Temperature rationale: 0.2 produces consistent, factual explanations. Higher values introduce stylistic variation which is not desirable for medical content where users may compare responses.

Vision mode: activated automatically when the upload contains scan images (X-ray, MRI, ultrasound, CT). Claude processes the image and the extracted radiologist text together.

---

## Stage 7: Output validation

Every response passes all of these checks before being returned. Non-negotiable.

### Schema validation
Response must match the expected JSON structure. On failure: retry up to 2 times, then return a fallback error response. Never return malformed JSON to the client.

```json
{
  "explanation": "string",
  "biomarkers": [
    {
      "name": "string",
      "status": "normal | borderline | high | low | critical",
      "plain_value": "string",
      "plain_range": "string",
      "trend": "improving | stable | worsening | first_reading",
      "source": "string"
    }
  ],
  "questions_for_doctor": ["string"],
  "urgency": "routine | follow_up | urgent | emergency",
  "disclaimer": "auto-injected — not from AI",
  "citations": ["string"]
}
```

### Hallucination check
Every cited reference range is checked against the corresponding KB chunk's structured `values` field. If Claude cites a range that does not match the retrieved chunk, the claim is suppressed and replaced with a note directing the user to consult their report header.

### Diagnosis detection
Regex + semantic scan for diagnostic language. Blocked patterns:
- "you have [condition]"
- "this indicates [diagnosis]"
- "you are suffering from"
- "this confirms"
- "your scan shows [finding]" (radiological diagnosis)
- "there is nothing to worry about" (false reassurance)

On detection: block the specific sentence, rephrase to educational framing, or return a partial response with the diagnostic claim removed.

### Critical value override
Rule engine independently checks every extracted biomarker value against a hardcoded emergency threshold table. If any value crosses a threshold, urgency is forced to `emergency` regardless of the AI's assessment.

The rule engine can only escalate urgency — it cannot de-escalate below the AI's determination. Both assessments run independently; the higher rating always wins.

---

## Stage 8: De-tokenization & personalisation

1. Replace all UUID tokens with original values using the server-side token map
2. Apply user language preference — for non-English users, run a translation pass on the `explanation` field only (not structured data)
3. Inject mandatory disclaimer string — configured per region, cannot be modified or omitted by AI output
4. Delete the token map from Redis

---

## Stage 9: Response delivery & logging

Delivery:
- Stream tokens to client as they arrive
- Render order: explanation → biomarker cards → doctor questions → disclaimer

Persistence (after full response delivered):
- Store: prompt version ID, model, latency, output JSON, urgency value, report ID
- Link to immutable audit log record created at query start
- Delete conversation from Redis (session cache only — conversation history stored in DB)

Feedback:
- Thumbs up/down on each biomarker explanation
- Feedback is stored as a labelled signal linked to the prompt version
- Used as training signal for prompt improvement pipeline

---

## Error handling

| Error type | Behaviour |
|---|---|
| OCR failure | Return partial results, flag affected fields, prompt user to re-upload |
| PII stripper failure | Abort request, return "processing error" to user, alert on-call |
| Input classifier error | Fail open (pass through) but log — classifier failure should never block a legitimate request |
| Claude API timeout | Retry once with reduced max_tokens, then return friendly error |
| Output schema failure | Retry up to 2x, then return plain-text fallback from a secondary simpler prompt |
| Emergency threshold triggered | Bypass AI entirely, return hardcoded emergency template immediately |
