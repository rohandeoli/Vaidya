# Knowledge base sources

## Source hierarchy

When multiple sources cover the same biomarker or topic, this priority order applies:

1. ICMR (Indian-specific data — always preferred for Indian users)
2. AIIMS / MoHFW (India national health system protocols)
3. WHO (global standard, used as fallback)
4. NIN (nutrition-specific queries)
5. NABL lab networks (specific reference range tables)
6. ADA / ESC / international bodies (only when no Indian guidance exists)
7. PubMed summaries (contextual only — never for reference ranges)

---

## Source catalogue

### ICMR — Indian Council of Medical Research

| Property | Value |
|---|---|
| Authority code | `icmr` |
| Region | `IN` |
| Estimated chunks | ~1,200 |
| Update frequency | Annual major release + ad-hoc |
| Priority rank | 1 (highest) |

Key documents to index:
- ICMR Consensus Guidelines on Diabetes (latest edition)
- ICMR Guidelines for Management of Hypertension
- ICMR Guidelines on Anaemia
- ICMR Standard Treatment Workflows (STW) — 21 disease categories
- ICMR Cancer Screening Guidelines
- ICMR-NIN reference values for Indian population

India-specific notes:
- ICMR BMI cutoffs for obesity risk in Indians are lower than WHO standards (23 kg/m² for overweight, 25 for obesity vs 25/30 in WHO)
- HbA1c reference ranges may differ slightly due to haemoglobin variant prevalence in Indian populations (sickle cell trait, beta-thalassemia — affects HbA1c assay accuracy)
- Vitamin D deficiency thresholds are calibrated for sun exposure patterns in India

---

### WHO — World Health Organization

| Property | Value |
|---|---|
| Authority code | `who` |
| Region | `GLOBAL` |
| Estimated chunks | ~800 |
| Update frequency | Annual or by topic |
| Priority rank | 3 |

Key documents to index:
- WHO Clinical Guidelines for Primary Health Care
- ICD-11 clinical descriptions (not codes — natural language descriptions)
- WHO nutrition reference values
- WHO cardiovascular risk assessment guidelines
- WHO mental health classification (for psychological health context)

Usage rule: WHO is the authoritative fallback when ICMR has no guidance on a specific biomarker or condition. In retrieval, ICMR chunks are given a source priority boost — if both an ICMR and WHO chunk score similarly, ICMR wins.

---

### AIIMS & MoHFW

| Property | Value |
|---|---|
| Authority code | `aiims` / `mohfw` |
| Region | `IN` |
| Estimated chunks | ~600 |
| Update frequency | As published |
| Priority rank | 2 |

Key documents to index:
- AIIMS clinical practice guidelines (cardiac, nephrology, endocrinology)
- MoHFW Ayushman Bharat Health and Wellness Centre clinical protocols
- National NCD (Non-Communicable Disease) prevention guidelines
- MoHFW maternal and child health screening guidelines
- National Iron Plus Initiative guidelines (anaemia)

---

### NABL-accredited lab networks

| Property | Value |
|---|---|
| Authority code | `lab_network` |
| Region | `IN` |
| Estimated chunks | ~2,400 |
| Update frequency | Quarterly review |
| Priority rank | 1 (for reference ranges specifically) |

Source labs (reference only — do not brand these in user-facing content):
- Major national diagnostic chains with NABL accreditation
- Reference ranges stratified by age group, sex, and sample type

This is the highest-volume source and the most directly useful for report explanation. One chunk per test per demographic stratum.

Critical note: Lab reference ranges can differ between labs. When a user's report header includes a reference range, that value takes precedence over KB ranges for that specific report. The KB range is used for educational context only when the report range is unclear.

---

### NIN — National Institute of Nutrition

| Property | Value |
|---|---|
| Authority code | `nin` |
| Region | `IN` |
| Estimated chunks | ~200 |
| Update frequency | As published |
| Priority rank | 1 (for nutrition queries) |

Key documents:
- Dietary Reference Values for Indians (ICMR-NIN 2020)
- Nutrient composition of Indian foods
- Recommended Dietary Allowances for the Indian population

Use for: nutrition-related queries ("what foods contain iron?", "what is vitamin D recommended intake?"). Never use for clinical diagnosis or treatment recommendations.

---

### PubMed research summaries

| Property | Value |
|---|---|
| Authority code | `pubmed` |
| Region | `IN` (India-cohort studies only) |
| Estimated chunks | ~400 |
| Update frequency | Monthly curation |
| Priority rank | 7 (lowest — contextual only) |

Inclusion criteria for PubMed abstracts:
- Study conducted in India or with a predominantly Indian cohort
- Published in a peer-reviewed journal with impact factor > 2.0
- Abstract must be in English
- Study type: RCT, meta-analysis, or large observational study (n > 500)

Evidence level tagging (stored in `content.evidence_level`):
- `rct` — randomised controlled trial
- `meta_analysis` — systematic review or meta-analysis
- `observational_large` — large cohort or case-control study

Usage rule: PubMed chunks are used only for contextual "why this matters" content. They are never used to support specific reference range values. The AI is instructed to use hedged language ("studies suggest", "research indicates") for PubMed-sourced claims, not the authoritative language used for ICMR/WHO guidance.

---

### Patient education content

| Property | Value |
|---|---|
| Authority code | `patient_edu` |
| Region | `IN` |
| Estimated chunks | ~900 |
| Update frequency | Continuous |
| Priority rank | Used alongside clinical sources |
| Languages | English, Hindi, Tamil |

This is the only KB section authored bottom-up rather than sourced from existing documents. Each entry is:
1. Written by a medical education specialist
2. Reviewed by a qualified clinician
3. Reviewed for plain-language accessibility
4. Tested against real user queries before ingestion

Format: Q&A pairs
```
Q: What does HbA1c measure?
A: HbA1c (sometimes called glycated haemoglobin or A1C) is a blood test
   that measures your average blood sugar level over the past 2-3 months.
   Unlike a fasting glucose test which shows your sugar at a single moment,
   HbA1c gives a longer-term picture of how well your blood sugar has
   been controlled.
```

The Q&A format retrieves significantly better than narrative text for conversational queries because the user's question closely matches the Q component.

Language variants share the same chunk ID with a `lang` suffix (`hba1c-edu-001-en`, `hba1c-edu-001-hi`, `hba1c-edu-001-ta`). The RAG pipeline selects the appropriate language variant based on the user's language preference in their profile.

---

## What is never ingested

The following content types are permanently excluded from the KB:

- Raw web content or blog posts (regardless of apparent authority)
- Drug dosage or prescribing information of any kind
- Single case studies or anecdotal clinical reports
- Content without a clearly dated, named source
- Social media content
- Content from sources with financial conflicts of interest in the topic area
- AI-generated content (no AI-written chunks in the KB)
- Any content not reviewed and approved by a qualified medical reviewer
