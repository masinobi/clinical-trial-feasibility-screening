# Clinical Trial Feasibility Screening Pipeline

## Project Objective

Translated a written Phase II type 2 diabetes protocol into validated T-SQL and executed a site feasibility screen against an 11,482-patient synthetic EHR extract. The pipeline evaluates five inclusion criteria and one exclusion criterion across four clinical domains, reports the eligible cohort and projected enrolment, and documents the data quality defects encountered during criteria translation.

The deliverable of a feasibility screen is not a query. It is a defensible answer to the question a sponsor is asking: can this site recruit for this protocol, and if not, which criterion is responsible.

## Tech Stack

- **Data source:** Synthea synthetic patient generator, CSV extract covering patients, conditions, medications, and laboratory observations
- **Database and analysis:** SQL Server (SSMS), T-SQL
- **Techniques:** Common Table Expressions, `ROW_NUMBER()` window functions with `PARTITION BY`, `NOT EXISTS` anti-joins, `TRY_CAST` defensive typing, date-window filtering
- **Standards context:** ICH E6 GCP, ALCOA+ data integrity principles, GCDMP Laboratory Data Handling

## Protocol Criteria

| # | Criterion | Type |
|---|---|---|
| 1 | Age 18 to 75 at index date | Inclusion |
| 2 | Confirmed type 2 diabetes mellitus diagnosis | Inclusion |
| 3 | Most recent HbA1c above 7.5 percent, within 365 days | Inclusion |
| 4 | Most recent eGFR between 30 and 60, within 365 days | Inclusion |
| 5 | Alive at index date | Inclusion |
| 6 | Insulin prescription active within 90 days | Exclusion |

Index date: 2017-12-31.

## Key Deliverables

### 1. Longitudinal Laboratory Modelling

Criteria 3 and 4 specify the *most recent* result, not any result within the window. A patient whose HbA1c was 9.1 percent two years ago and 6.2 percent last month does not qualify. This was implemented with CTEs applying `ROW_NUMBER() OVER (PARTITION BY patient, test ORDER BY test_date DESC)` and filtering to rank 1, partitioning on both patient and test type so that each subject retains the latest result of each assay rather than a single most recent laboratory record overall.

### 2. Diagnosis Code Validation

The extract codes conditions in SNOMED CT rather than ICD-10, so pattern matching on ICD-10 chapter prefixes returns nothing. Beyond the coding system, the base diagnosis code proved insufficient on its own.

An anti-join comparing patients carrying type 2 diabetes complication codes against those carrying the base diagnosis code identified **733 patients with documented type 2 diabetes recorded only under a complication**, such as diabetic neuropathy or nonproliferative retinopathy. Restricting the cohort to the base code alone would have excluded 46 percent of the diabetic population and understated site recruitment capacity accordingly.

One code, `127013003 Disorder of kidney due to diabetes mellitus`, does not specify diabetes type and cannot be resolved from the data. Under GCP this is escalated to the Data Manager or Medical Monitor for a documented decision rather than resolved by analyst judgement, since it materially changes the eligible cohort and must be traceable at inspection.

### 3. Data Integrity Safeguards

Laboratory results are stored as text. Typing was applied in query via `TRY_CAST(... AS DECIMAL(10,2))` rather than by altering the source extract, for two reasons.

First, precision. An `ALTER TABLE ... DECIMAL` without explicit scale defaults to zero decimal places in SQL Server, rounding 7.4 to 7 and 7.5 to 8. Applied to this dataset, that defect inflates the HbA1c-eligible cohort from 4 patients to 10, enrolling six subjects who do not meet the glycaemic entry criterion.

Second, integrity. Received clinical data is not modified in place. ALCOA+ requires the original record to remain intact and attributable, and a destructive type change leaves no audit trail of the prior values.

`TRY_CAST` was chosen over `CAST` so that non-numeric laboratory values, which appear routinely in real transfers as qualified results such as "<0.5" or "NOT DONE", return NULL rather than failing the batch.

### 4. Feasibility Outcome

| Filter | Patients |
|---|---|
| Total in extract | 11,482 |
| Age 18 to 75 at index | 7,404 |
| Alive at index and in age range | 6,823 |
| Latest HbA1c above 7.5 | 4 |
| Latest eGFR between 30 and 60 | 90 |
| **Meeting both laboratory criteria** | **0** |

The site cannot enrol under this protocol as written. The two laboratory criteria are individually satisfiable but do not intersect, and the HbA1c threshold is the binding constraint. Reported in this form, the medical monitor can see immediately which criterion to reconsider rather than only that the screen returned nothing.

## Data Quality Findings

Four defects were encountered during criteria translation, none of which raise an error at execution:

1. Diagnosis coding system differs from the protocol assumption (SNOMED CT rather than ICD-10)
2. Diagnoses recorded under complication codes without the base condition code
3. Laboratory results stored as text, comparing incorrectly if typed without explicit scale
4. eGFR reported under one LOINC code with two unit variants, `mL/min/{1.73_m2}` and `mL/min`

Each produces a plausible but incorrect cohort rather than a visible failure, which is the characteristic risk profile of eligibility screening logic and the reason criteria translation is reviewed rather than assumed correct.
