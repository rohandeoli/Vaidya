# Urgency matrix

## Four urgency tiers

### Tier 1 — Routine

**Criteria:** All values within normal range, or minor deviations within borderline range. No trend deterioration. No concerning context flags.

**User-facing CTA:** "These results are worth reviewing at your next routine checkup. Keep a copy to share with your doctor."

**Response behaviour:** Standard educational explanation. No elevated CTA. Doctor visit timeframe: next scheduled appointment.

---

### Tier 2 — Follow-up

**Criteria:** One or more values outside normal range but not critically so. Or: values within range but showing a worsening trend over multiple reports. Or: user-declared context that increases the significance of a borderline value.

**User-facing CTA:** "These results are worth discussing with your doctor soon — within the next few weeks if possible."

**Response behaviour:** Educational explanation with trend commentary. Specific questions for the doctor. Moderately elevated CTA placement.

---

### Tier 3 — Urgent

**Criteria:** One or more values significantly outside normal range. Or: multiple values trending in the same concerning direction. Or: combination of values that together warrant prompt evaluation.

**User-facing CTA:** "These results should be reviewed by your doctor this week. Please don't wait for your next routine appointment — call and schedule a visit."

**Response behaviour:** CTA leads the response (before explanation). Explanation is factual and calm. Questions for doctor are direct and specific.

---

### Tier 4 — Emergency

**Criteria:** Any biomarker value crosses a hardcoded critical threshold (see table below). Or: radiologist report text contains emergency keywords.

**User-facing response:** Hardcoded template only. No AI-generated content. See [`GUARDRAILS.md`](GUARDRAILS.md).

**Response behaviour:** Bypass AI pipeline entirely. Return emergency template. Log event. Optionally trigger push notification to the user (non-suppressible channel).

---

## Critical value thresholds (hardcoded rule engine)

These values trigger an automatic `emergency` urgency override. The list is maintained by the medical team and updated through the KB lifecycle process — not by engineers alone.

| Test | Critical low | Critical high | Unit |
|---|---|---|---|
| Haemoglobin | < 7.0 | > 20.0 | g/dL |
| Potassium | < 2.5 | > 6.5 | mEq/L |
| Sodium | < 120 | > 160 | mEq/L |
| Glucose (fasting) | < 50 | > 500 | mg/dL |
| Creatinine | — | > 10.0 | mg/dL |
| INR / PT | — | > 4.5 | ratio |
| Troponin I | — | > 0.4 | ng/mL |
| pH (blood gas) | < 7.20 | > 7.60 | — |
| Platelets | < 20,000 | > 1,000,000 | /µL |
| WBC | < 1,000 | > 100,000 | /µL |

Radiologist report keywords that trigger emergency (case-insensitive):
- "acute MI" / "myocardial infarction"
- "aortic dissection"
- "pulmonary embolism"
- "intracranial haemorrhage"
- "tension pneumothorax"
- "bowel perforation"
- "acute appendicitis"
- "ruptured [any organ]"

This list must be reviewed and approved by a licensed physician before any changes are deployed.

---

## Urgency determination logic

Urgency is computed by two independent systems. The higher rating always wins.

```
┌──────────────────────────┐    ┌───────────────────────────┐
│  Rule engine             │    │  AI assessment            │
│  (deterministic)         │    │  (from structured output) │
│                          │    │                           │
│  Check each biomarker    │    │  Claude returns           │
│  value against threshold │    │  urgency field in JSON    │
│  table                   │    │                           │
│                          │    │                           │
│  Output: urgency_rule    │    │  Output: urgency_ai       │
└──────────┬───────────────┘    └──────────────┬────────────┘
           │                                   │
           └──────────────┬────────────────────┘
                          │
                          ▼
              final_urgency = max(urgency_rule, urgency_ai)
              where emergency > urgent > follow_up > routine
```

**Why both systems?**
- The rule engine catches values the AI might downplay due to reassuring surrounding context
- The AI catches nuanced cases — e.g. a value technically within range but clinically significant given the user's medication context or age
- Neither system alone is sufficient; both are required

**Critical constraint:** The rule engine can only escalate urgency, never de-escalate. If the rule engine determines `emergency`, the AI's lower urgency assessment is ignored entirely and the emergency template is served.
