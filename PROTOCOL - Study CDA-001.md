# Protocol CDA-001 — Feasibility Screening Specification

**Purpose:** Identify patients potentially eligible for a Phase II type 2 diabetes trial from the site's EHR extract.
**Your deliverable:** One SQL query returning the eligible cohort.
**Data:** Synthea synthetic EHR — 11,482 patients. No real patient data; safe to work with freely.

This is written the way a real feasibility request arrives: as clinical criteria, not as SQL. Translating it is the exercise.

---

## Tables

**`patients`** — 11,482 rows
`PATIENT_ID` · `BIRTHDATE` · `DEATHDATE` · `GENDER` · `RACE` · `ETHNICITY` · `CITY` · `STATE`

**`conditions`** — 14,567 rows (diabetes, kidney, hypertension only)
`PATIENT_ID` · `ONSET_DATE` · `RESOLVED_DATE` · `SNOMED_CODE` · `DESCRIPTION`

**`medications`** — 69,390 rows (diabetes-relevant only)
`PATIENT_ID` · `START_DATE` · `STOP_DATE` · `RXNORM_CODE` · `DESCRIPTION`

**`lab_results`** — 133,131 rows (HbA1c and eGFR only)
`PATIENT_ID` · `TEST_DATE` · `LOINC_CODE` · `TEST_NAME` · `RESULT_VALUE` · `UNITS`

| Lab | LOINC |
|---|---|
| HbA1c | `4548-4` |
| eGFR (MDRD) | `33914-3` |

---

## Screening index date

Use **2017-12-31** as "today." The data ends around then, so `CURRENT_DATE` returns nothing.

## Inclusion criteria

1. Age **18–75** at index date
2. Confirmed **type 2 diabetes mellitus** diagnosis
3. **Most recent HbA1c > 7.5%**, drawn within **365 days** before index
4. **Most recent eGFR between 30 and 60**, drawn within **365 days** before index
5. Alive at index date

## Exclusion criteria

6. Any **insulin** prescription active within **90 days** before index date

---

## What "most recent" means

Criteria 3 and 4 say *most recent*, not *any*. A patient with a 9.1% HbA1c two years ago and 6.2% last month does **not** qualify. Getting this wrong is the single most common error in feasibility queries, and it inflates your enrollment estimate — which is the number the sponsor plans a budget around.

---

## Deliverable

A query returning one row per eligible patient:

`PATIENT_ID` · `AGE_AT_INDEX` · `LATEST_HBA1C` · `LATEST_EGFR`

Then a second query: eligible patients grouped by `STATE`, with an estimated enrollment at a 20% consent rate.

---

## Ground rules

Write it yourself before looking at `gemini-code-hosptial.sql`. That file solves a similar problem against a different schema — reading it first turns this into transcription. Write, run, then diff.

You'll need: CTEs · `ROW_NUMBER() OVER (PARTITION BY … ORDER BY …)` · a date-window filter · an anti-join for the exclusion · a cast.

---

## Four things this data will do to you

Real EHR extracts fight back. Each of these is in here deliberately.

1. **The codes aren't ICD-10.** The Gemini query matched `icd10_code LIKE 'E11%'`. This extract uses SNOMED CT. Find the right code before you write the join — and check whether one code is enough, given there are several diabetes-related descriptions.

2. **`RESULT_VALUE` is text.** Comparing it numerically without a cast will either error or, worse, compare as strings — where `'9.1' < '7.5'` is true. Silent wrongness again.

3. **eGFR has two unit variants under one LOINC code** — `mL/min/{1.73_m2}` and `mL/min`. Decide whether to treat them as equivalent, and be able to defend the decision. This is exactly the "standardized names for lab tests and units" minimum standard from the GCDMP *Laboratory Data Handling* chapter.

4. **There are no SGLT2 inhibitors in this dataset.** The exclusion criterion above says insulin instead. Confirm what's actually in `medications` before assuming any drug class exists — real feasibility work is full of criteria that can't be evaluated against available data, and saying so is part of the job.

---

## Why this is worth doing properly

Your resume claims *"SQL database views using CTEs and window functions"* and *"anti-join cleaning logic."* When you've written this unaided against messy data and can explain each decision, that claim is yours. It also becomes a far better portfolio piece than the readmissions project — trial feasibility screening is the actual work of clinical data management.

When you have a result, send it and I'll interview you on it the way a CRO hiring manager would.
