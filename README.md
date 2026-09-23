# Clinical Trial Feasibility Screening Pipeline

## Project Objective

Translated a written Phase II type 2 diabetes protocol into validated T-SQL and executed a site feasibility screen against an 11,482-patient synthetic EHR extract. The pipeline evaluates five inclusion criteria and one exclusion criterion across four clinical domains, reports the eligible cohort and projected enrolment, and documents the data quality defects encountered during criteria translation.

The deliverable of a feasibility screen is not a query. It is a defensible answer to the question a sponsor is asking: can this site recruit for this protocol, and if not, which criterion is responsible.

## Tech Stack

- **Data source:** Synthea synthetic patient generator, CSV extract covering patients, conditions, medications, and laboratory observations
- **Database and analysis:** SQL Server (SSMS), T-SQL
- **Techniques:** SNOMED CT and RxNorm code lists, `RANK()` window functions with `PARTITION BY`, `NOT EXISTS` anti-joins, `TRY_CAST` defensive typing, half-open date windows
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

Criteria 3 and 4 specify the *most recent* result, not any result within the window. A patient whose HbA1c was 9.1 percent two years ago and 6.2 percent last month does not qualify. This was implemented with `RANK() OVER (PARTITION BY patient, test ORDER BY test_date DESC)`, partitioning on both patient and test type so that each subject retains the latest result of each assay rather than a single most recent laboratory record overall. The thresholds are applied after the ranking, not before it: filtering first would return each patient's latest result *above* 7.5, which is a different cohort.

`RANK` rather than `ROW_NUMBER`, because the extract does not always have a single latest result. For 682 patient-timestamps in the window, the same eGFR test is recorded twice at the same second with different values. `ROW_NUMBER` keeps one of them, and which one is not defined; `RANK` keeps both, and a criterion counts as met only if every value at that timestamp meets it. The conflicts are listed for review by a separate output rather than resolved inside the query.

### 2. Diagnosis Code Validation

The extract codes conditions in SNOMED CT rather than ICD-10, so pattern matching on ICD-10 chapter prefixes returns nothing. Criterion 2 is applied with an explicit code list: descriptions were used to *build* and audit the list, and the codes apply it.

Description matching is not a safe substitute. The base diagnosis reads `Diabetes mellitus type 2 (disorder)`, so a search for `type 2 diabetes` matches every complication and misses the base code itself. On this extract that finds 1,219 patients where the code list finds 1,581.

The base code alone is not enough either. An anti-join comparing patients carrying type 2 diabetes complication codes against those carrying the base code identified **733 patients across the extract with type 2 diabetes recorded only under a complication**, such as diabetic neuropathy or nonproliferative retinopathy. Restricting to the base code would have excluded 46 percent of the diabetic population and understated site recruitment capacity accordingly.

Two codes are held out deliberately. `714628002 Prediabetes` is not diabetes. `127013003 Disorder of kidney due to diabetes mellitus` does not state the diabetes type and cannot be resolved from the data; under GCP it is held out pending a documented decision from the Data Manager or Medical Monitor rather than resolved by analyst judgement, since it materially changes the eligible cohort and must be traceable at inspection.

The diagnosis must also be recorded on or before the index date. Without that condition, 422 patients whose only type 2 diabetes code appears after 2017 would count as diabetic at a 2017 screen.

The insulin exclusion follows the same rule: a description search for `insulin` matches exactly three RxNorm products in this extract, all of them insulin, and those three codes are what the query applies.

### 3. Data Integrity Safeguards

Laboratory results arrive from the extract as text. This load typed the column as `FLOAT`, but the query casts explicitly with `TRY_CAST(... AS DECIMAL(10,2))` so that its behaviour does not depend on how a particular load typed the column, and so that a qualified result such as `<0.5` or `NOT DONE` returns NULL rather than failing the batch.

The scale is explicit for a reason. A `DECIMAL` without one rounds 7.4 to 7 and 7.5 to 8. Applied to this dataset, that inflates the HbA1c-eligible cohort from 4 patients to 10, enrolling six subjects who do not meet the glycaemic entry criterion.

The typing is applied in the query rather than by altering the source table. Received clinical data is not modified in place: ALCOA+ requires the original record to remain intact and attributable, and a destructive type change leaves no audit trail of the prior values.

Date windows are half-open. `TEST_DATE` and the medication dates carry a time of day, so a window closing on `<= '2017-12-31'` actually closes at midnight at the start of the index day and silently drops everything recorded during it. The query uses `< '2018-01-01'`.

### 4. Feasibility Outcome

Every count below is produced by Output 3 of `CDA-001 Feasibility Screen.sql`. Each criterion is applied to the age-and-alive cohort on its own, so the table shows which criterion binds rather than the order the criteria were written in.

| Filter | Patients |
|---|---|
| Total in extract | 11,482 |
| Age 18 to 75 and alive at index | 6,823 |
| with type 2 diabetes diagnosed by index | 733 |
| with latest HbA1c above 7.5 | 4 |
| with latest eGFR between 30 and 60 | 57 |
| **Meeting both laboratory criteria** | **0** |

The 733 here is not the 733 in section 2. That figure counts complication-only patients across the whole extract; this one counts diagnosed patients within the screening cohort. Only 283 patients are in both, and the matching totals are a coincidence.

The site cannot enrol under this protocol as written. The two laboratory criteria are individually satisfiable but do not intersect, and the HbA1c threshold is the binding constraint: four patients clear it. Reported in this form, the medical monitor can see immediately which criterion to reconsider rather than only that the screen returned nothing.

The result holds under every reasonable handling of the eGFR conflicts. Taking either value at a tied timestamp, or requiring both, still leaves no patient meeting both laboratory criteria.

## Data Quality Findings

Six defects were encountered during criteria translation. None raises an error at execution:

1. Diagnosis coding system differs from the protocol assumption (SNOMED CT rather than ICD-10).
2. Diagnoses recorded under complication codes without the base condition code.
3. Laboratory results delivered as text, comparing incorrectly if typed without explicit scale.
4. eGFR reported under one LOINC code with two unit labels, `mL/min/{1.73_m2}` and `mL/min`. Both carry the same test name, MDRD normalised to 1.73 m², so they are treated as one measurement with an inconsistent unit label rather than as two measurements needing conversion.
5. The same eGFR test recorded twice at the same second with different values, for 682 patient-timestamps in the window: for example 148.8 and 66.6. For 36 patients in the screening cohort, one value would meet criterion 4 and the other would not. These are listed by Output 4 for review rather than resolved in the query.
6. The UTC offset on laboratory timestamps (`2017-12-14 12:17:59-08`) was read as fractional seconds on import (`12:17:59.08`). The local time survives, so the date windows are unaffected, but the time zone is lost.

Each produces a plausible but incorrect cohort rather than a visible failure, which is the characteristic risk profile of eligibility screening logic and the reason criteria translation is reviewed rather than assumed correct.

## Corrections

The first published version of this screen contained three errors, found on re-verifying the published numbers against the data. The headline result, zero eligible patients, was unaffected by all three.

- **Criterion 2 matched descriptions instead of codes**, which missed the 362 patients whose only type 2 diabetes code was the base diagnosis. It also counted diagnoses recorded after the index date. It now applies a code list, restricted to diagnoses on or before the index date.
- **The eGFR count in the outcome table used the wrong denominator.** It reported 90, which was the count across the whole extract, in a table where every other row used the age-and-alive cohort. Within the cohort, the first version's query gave 70, and that figure depended on which of two conflicting results `ROW_NUMBER` happened to keep. With conflicts handled explicitly, the figure is 57.
- **The laboratory window closed at the start of the index day** and dropped the 21 results recorded on it. It now runs from 2017-01-01 to the end of the index day. The first version ran one day earlier at both ends; on this extract that moves no count.

The outcome table is now generated by the query itself, so a count in this README can always be traced to the code that produced it.
