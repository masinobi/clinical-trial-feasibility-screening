/* =============================================================
   Protocol CDA-001 - Feasibility Screen
   Index date: 2017-12-31

   Where each criterion lives:
     1  Age 18-75 .............. WHERE        (patients)
     2  Type 2 diabetes ........ EXISTS       (conditions, SNOMED code list)
     3  Latest HbA1c > 7.5 ..... JOIN + WHERE (lab_results)
     4  Latest eGFR 30-60 ...... JOIN + WHERE (lab_results)
     5  Alive at index ......... WHERE        (patients)
     6  No recent insulin ...... NOT EXISTS   (medications, RxNorm code list)

   Date boundaries. TEST_DATE, START_DATE and STOP_DATE are DATETIME2, so
   windows end with < '2018-01-01'. Writing <= '2017-12-31' compares against
   midnight at the START of the index day and silently drops everything
   recorded during it - 21 laboratory results in this extract. ONSET_DATE,
   BIRTHDATE and DEATHDATE are DATE, where <= '2017-12-31' is exact.

   Everything in the README is produced by Output 3 below. If a number in
   the README cannot be regenerated from this file, it should not be there.
   ============================================================= */

USE Practice;
GO

DROP TABLE IF EXISTS #T2DM_Codes, #Insulin_Codes, #LatestLabs, #Eligible;

/* ---------- criterion 2: type 2 diabetes code list ----------
   Descriptions build and audit the list; codes apply it.

   The first version of this query matched descriptions -
   LIKE '%type 2 diabetes%' OR LIKE '%type II diabetes%' - and found 1,219
   patients. It caught every complication and missed the base code itself,
   whose description reads 'Diabetes mellitus type 2 (disorder)': word order.
   The code list finds 1,581.

   Held out, deliberately:
     714628002  Prediabetes (finding) - not diabetes
     127013003  Disorder of kidney due to diabetes mellitus - does not state
                the diabetes type, so it cannot be resolved from the data.
                Held out pending a documented decision from the Data
                Manager or Medical Monitor, not resolved here.
   ------------------------------------------------------------- */
CREATE TABLE #T2DM_Codes (SNOMED_CODE BIGINT PRIMARY KEY, DESCRIPTION NVARCHAR(200));
INSERT INTO #T2DM_Codes VALUES
    (44054006,        N'Diabetes mellitus type 2 (disorder)'),
    (368581000119106, N'Neuropathy due to type 2 diabetes mellitus (disorder)'),
    (1551000119108,   N'Nonproliferative diabetic retinopathy due to type II diabetes mellitus'),
    (1501000119109,   N'Proliferative diabetic retinopathy due to type II diabetes mellitus'),
    (97331000119101,  N'Macular edema and retinopathy due to type 2 diabetes mellitus (disorder)'),
    (90781000119102,  N'Microalbuminuria due to type 2 diabetes mellitus (disorder)'),
    (157141000119108, N'Proteinuria due to type 2 diabetes mellitus (disorder)'),
    (60951000119105,  N'Blindness due to type 2 diabetes mellitus (disorder)');

/* ---------- criterion 6: insulin code list ----------
   Built from DESCRIPTION LIKE '%insulin%', which matches exactly these three
   products in this extract, all of them insulin. The search built the list;
   the codes apply it, the same rule as criterion 2. */
CREATE TABLE #Insulin_Codes (RXNORM_CODE INT PRIMARY KEY, DESCRIPTION NVARCHAR(200));
INSERT INTO #Insulin_Codes VALUES
    (106892, N'insulin isophane human 70 UNT/ML / insulin regular human 30 UNT/ML Injectable Suspension'),
    (865098, N'Insulin Lispro 100 UNT/ML Injectable Solution [Humalog]'),
    (311034, N'insulin regular human 100 UNT/ML Injectable Solution');

/* ---------- criteria 3 and 4: the latest result of each assay ----------
   One pass over both assays, partitioned by patient AND test, so each
   patient keeps the latest HbA1c and the latest eGFR rather than a single
   most recent laboratory record overall.

   RANK, not ROW_NUMBER. For 682 patient-timestamps in the window, Synthea
   records two different eGFR values for the same test at the same second -
   148.8 and 66.6, for example. ROW_NUMBER keeps one of them, and which one
   is undefined; it was silently deciding whether 36 patients met criterion
   4. RANK keeps every row at the latest timestamp, and a criterion is met
   only if ALL of them meet it. Conflicting values are listed for review in
   Output 4, not resolved here - the same rule as for 127013003.

   eGFR units. Results arrive labelled both 'mL/min/{1.73_m2}' and 'mL/min'.
   Both carry the same test name - MDRD, normalised to 1.73 sq M - so they
   are treated as one measurement with an inconsistent unit label, not as
   two measurements needing conversion.

   TRY_CAST, not CAST. This load typed RESULT_VALUE as FLOAT, but extracts
   arrive as text and a qualified result such as '<0.5' must return NULL
   rather than fail the batch. DECIMAL(10,2), with an explicit scale: a
   DECIMAL without one rounds 7.4 to 7 and 7.5 to 8, which in this extract
   turns 4 HbA1c-eligible patients into 10.
   -------------------------------------------------------------------- */
SELECT PATIENT_ID, LOINC_CODE,
       MIN(RESULT_NUM) AS LO,
       MAX(RESULT_NUM) AS HI,
       MAX(TEST_DATE)  AS TEST_DATE
INTO #LatestLabs
FROM (
    SELECT PATIENT_ID, LOINC_CODE, TEST_DATE,
           TRY_CAST(RESULT_VALUE AS DECIMAL(10,2)) AS RESULT_NUM,
           RANK() OVER (PARTITION BY PATIENT_ID, LOINC_CODE ORDER BY TEST_DATE DESC) AS rk
    FROM lab_results
    WHERE LOINC_CODE IN ('4548-4', '33914-3')
      -- 365 days ending on, and including, the index date. The first version
      -- started at DATEADD(day, -365, '2017-12-31'), which is 2016-12-31, and
      -- ended at the start of the index day: also 365 days, one day earlier at
      -- both ends. On this extract the shift moves no count.
      AND TEST_DATE >= '2017-01-01'
      AND TEST_DATE <  '2018-01-01'
    -- No threshold here. Filtering before the ranking would return each
    -- patient's latest result ABOVE 7.5, not their latest result.
) ranked
WHERE rk = 1
GROUP BY PATIENT_ID, LOINC_CODE;

/* ---------- the eligible cohort, defined once ----------
   Both deliverables read from #Eligible. The earlier version repeated the
   whole screen for the enrolment projection, which is two definitions of
   eligibility waiting to drift apart. */
SELECT p.PATIENT_ID, p.STATE,
       DATEDIFF(year, p.BIRTHDATE, '2017-12-31')
         - CASE WHEN DATEADD(year, DATEDIFF(year, p.BIRTHDATE, '2017-12-31'), p.BIRTHDATE)
                     > '2017-12-31' THEN 1 ELSE 0 END   AS AGE_AT_INDEX,
       a.LO                                             AS LATEST_HBA1C,
       g.LO                                             AS LATEST_EGFR
INTO #Eligible
FROM patients p
JOIN #LatestLabs a ON a.PATIENT_ID = p.PATIENT_ID AND a.LOINC_CODE = '4548-4'
JOIN #LatestLabs g ON g.PATIENT_ID = p.PATIENT_ID AND g.LOINC_CODE = '33914-3'
WHERE p.BIRTHDATE <= DATEADD(year, -18, '2017-12-31')          -- 1
  AND p.BIRTHDATE >  DATEADD(year, -76, '2017-12-31')          -- 1
  AND (p.DEATHDATE IS NULL OR p.DEATHDATE > '2017-12-31')      -- 5
  AND a.LO > 7.5                                               -- 3: every latest result above 7.5
  AND g.LO >= 30 AND g.HI <= 60                                -- 4: every latest result within 30-60
  AND EXISTS (                                                 -- 2
        SELECT 1 FROM conditions c
        JOIN #T2DM_Codes t ON t.SNOMED_CODE = c.SNOMED_CODE
        WHERE c.PATIENT_ID = p.PATIENT_ID
          AND c.ONSET_DATE <= '2017-12-31'                     -- diagnosed by the index date
  )
  AND NOT EXISTS (                                             -- 6
        SELECT 1 FROM medications m
        JOIN #Insulin_Codes i ON i.RXNORM_CODE = m.RXNORM_CODE
        WHERE m.PATIENT_ID = p.PATIENT_ID
          AND m.START_DATE < '2018-01-01'                      -- began before the window ended
          AND (m.STOP_DATE IS NULL                             -- still running
            OR m.STOP_DATE >= DATEADD(day, -90, '2017-12-31')) -- or ended after the window began
  );


/* =============================================================
   Output 1: the eligible cohort, in the protocol's output format
   ============================================================= */
SELECT PATIENT_ID, AGE_AT_INDEX, LATEST_HBA1C, LATEST_EGFR
FROM #Eligible
ORDER BY PATIENT_ID;


/* =============================================================
   Output 2: projected enrolment by state at 20% consent
   ============================================================= */
SELECT STATE,
       COUNT(*)                 AS ELIGIBLE_PATIENTS,
       FLOOR(COUNT(*) * 0.20)   AS PROJECTED_ENROLMENT
FROM #Eligible
GROUP BY STATE
ORDER BY ELIGIBLE_PATIENTS DESC;


/* =============================================================
   Output 3: the funnel. Every count in the README comes from here.

   Each criterion is applied to the age-and-alive cohort on its own, so
   the rows show which criterion binds rather than the order they were
   written in. The earlier README took its eGFR figure (90) from the whole
   extract while every neighbouring row used this cohort; within the
   cohort the figure was 70.
   ============================================================= */
WITH Cohort AS (
    SELECT PATIENT_ID FROM patients
    WHERE BIRTHDATE <= DATEADD(year, -18, '2017-12-31')
      AND BIRTHDATE >  DATEADD(year, -76, '2017-12-31')
      AND (DEATHDATE IS NULL OR DEATHDATE > '2017-12-31')
),
Diagnosed AS (
    SELECT DISTINCT c.PATIENT_ID
    FROM conditions c JOIN #T2DM_Codes t ON t.SNOMED_CODE = c.SNOMED_CODE
    WHERE c.ONSET_DATE <= '2017-12-31'
),
HbA1cMet AS (SELECT PATIENT_ID FROM #LatestLabs WHERE LOINC_CODE = '4548-4'  AND LO > 7.5),
EgfrMet  AS (SELECT PATIENT_ID FROM #LatestLabs WHERE LOINC_CODE = '33914-3' AND LO >= 30 AND HI <= 60)
SELECT 1 AS step, 'Total in extract' AS filter, COUNT(*) AS patients FROM patients
UNION ALL SELECT 2, 'Age 18 to 75 and alive at index', COUNT(*) FROM Cohort
UNION ALL SELECT 3, '  with type 2 diabetes diagnosed by index', COUNT(*)
          FROM Cohort c JOIN Diagnosed d ON d.PATIENT_ID = c.PATIENT_ID
UNION ALL SELECT 4, '  with latest HbA1c above 7.5', COUNT(*)
          FROM Cohort c JOIN HbA1cMet h ON h.PATIENT_ID = c.PATIENT_ID
UNION ALL SELECT 5, '  with latest eGFR between 30 and 60', COUNT(*)
          FROM Cohort c JOIN EgfrMet e ON e.PATIENT_ID = c.PATIENT_ID
UNION ALL SELECT 6, '  meeting both laboratory criteria', COUNT(*)
          FROM Cohort c JOIN HbA1cMet h ON h.PATIENT_ID = c.PATIENT_ID
                        JOIN EgfrMet  e ON e.PATIENT_ID = c.PATIENT_ID
UNION ALL SELECT 7, 'Eligible on every criterion', COUNT(*) FROM #Eligible
ORDER BY step;


/* =============================================================
   Output 4: conflicting simultaneous eGFR results, for review

   Patients in the cohort whose latest eGFR is two different values at the
   same timestamp. Not resolved by the query: listed so the discrepancy
   can be raised with whoever owns the source data.
   ============================================================= */
SELECT l.PATIENT_ID, l.TEST_DATE, l.LO AS EGFR_LOW, l.HI AS EGFR_HIGH,
       -- 'Yes' where exactly one value would qualify: the patients whose
       -- eligibility the old tie-break was silently deciding. If both values
       -- qualify, or neither does, the conflict does not change the answer.
       CASE WHEN (CASE WHEN l.LO BETWEEN 30 AND 60 THEN 1 ELSE 0 END)
               + (CASE WHEN l.HI BETWEEN 30 AND 60 THEN 1 ELSE 0 END) = 1
            THEN 'Yes' ELSE 'No' END                    AS CRITERION_4_DEPENDS_ON_IT
FROM #LatestLabs l
JOIN patients p ON p.PATIENT_ID = l.PATIENT_ID
WHERE l.LOINC_CODE = '33914-3'
  AND l.LO <> l.HI
  AND p.BIRTHDATE <= DATEADD(year, -18, '2017-12-31')
  AND p.BIRTHDATE >  DATEADD(year, -76, '2017-12-31')
  AND (p.DEATHDATE IS NULL OR p.DEATHDATE > '2017-12-31')
ORDER BY CRITERION_4_DEPENDS_ON_IT DESC, l.PATIENT_ID;
