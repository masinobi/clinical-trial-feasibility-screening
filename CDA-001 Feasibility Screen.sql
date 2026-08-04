/* =============================================================
   Protocol CDA-001 - Feasibility Screen
   Index date: 2017-12-31

   Where each criterion lives:
     1  Age 18-75 .............. WHERE      (patients)
     2  Type 2 diabetes ........ EXISTS     (conditions)
     3  Latest HbA1c > 7.5 ..... JOIN + WHERE (lab_results)
     4  Latest eGFR 30-60 ...... JOIN + WHERE (lab_results)
     5  Alive at index ......... WHERE      (patients)
     6  No recent insulin ...... NOT EXISTS (medications)

   ============================================================= */

USE Practice;
GO

WITH RankedLabs AS (        -- criterion 3: latest HbA1c per patient
    SELECT PATIENT_ID,
           TRY_CAST(RESULT_VALUE AS DECIMAL(10,2)) AS RESULT_NUM,
           ROW_NUMBER() OVER (PARTITION BY PATIENT_ID ORDER BY TEST_DATE DESC) AS rn
    FROM lab_results
    WHERE LOINC_CODE = '4548-4'
      AND TEST_DATE >= DATEADD(day, -365, '2017-12-31')
      AND TEST_DATE <= '2017-12-31'
    -- NOTE: no 7.5 threshold here. Filtering before the ranking would
    -- return each patient's latest result ABOVE 7.5, not their latest result.
),
RankedGFR AS (              -- criterion 4: latest eGFR per patient
    SELECT PATIENT_ID,
           TRY_CAST(RESULT_VALUE AS DECIMAL(10,2)) AS RESULT_NUM,
           ROW_NUMBER() OVER (PARTITION BY PATIENT_ID ORDER BY TEST_DATE DESC) AS gfr
    FROM lab_results
    WHERE LOINC_CODE = '33914-3'
      AND TEST_DATE >= DATEADD(day, -365, '2017-12-31')
      AND TEST_DATE <= '2017-12-31'
    -- same reason: the 30-60 range is applied outside, after ranking
)
SELECT p.PATIENT_ID,
       DATEDIFF(year, p.BIRTHDATE, '2017-12-31')
         - CASE WHEN DATEADD(year, DATEDIFF(year, p.BIRTHDATE, '2017-12-31'), p.BIRTHDATE)
                     > '2017-12-31' THEN 1 ELSE 0 END   AS AGE_AT_INDEX,
       a.RESULT_NUM                                     AS LATEST_HBA1C,
       g.RESULT_NUM                                     AS LATEST_EGFR
FROM patients p
JOIN RankedLabs a ON a.PATIENT_ID = p.PATIENT_ID AND a.rn  = 1
JOIN RankedGFR  g ON g.PATIENT_ID = p.PATIENT_ID AND g.gfr = 1
WHERE p.BIRTHDATE <= DATEADD(year, -18, '2017-12-31')          -- 1
  AND p.BIRTHDATE >  DATEADD(year, -76, '2017-12-31')          -- 1
  AND (p.DEATHDATE IS NULL OR p.DEATHDATE > '2017-12-31')      -- 5
  AND a.RESULT_NUM > 7.5                                       -- 3
  AND g.RESULT_NUM BETWEEN 30 AND 60                           -- 4
  AND EXISTS (                                                 -- 2
        SELECT 1 FROM conditions c
        WHERE c.PATIENT_ID = p.PATIENT_ID
          AND (c.DESCRIPTION LIKE '%type 2 diabetes%'
            OR c.DESCRIPTION LIKE '%type II diabetes%')
        -- description match, not code match: 733 patients carry only a
        -- complication code. 127013003 is excluded because it does not
        -- state the diabetes type.
  )
  AND NOT EXISTS (                                             -- 6
        SELECT 1 FROM medications m
        WHERE m.PATIENT_ID = p.PATIENT_ID
          AND m.DESCRIPTION LIKE '%insulin%'
          AND m.START_DATE <= '2017-12-31'                     -- began before window ended
          AND (m.STOP_DATE IS NULL                             -- still running
            OR m.STOP_DATE >= DATEADD(day, -90, '2017-12-31')) -- or ended after window began
  );


/* =============================================================
   Second deliverable: projected enrolment by state at 20% consent
   ============================================================= */

WITH RankedLabs AS (
    SELECT PATIENT_ID, TRY_CAST(RESULT_VALUE AS DECIMAL(10,2)) AS RESULT_NUM,
           ROW_NUMBER() OVER (PARTITION BY PATIENT_ID ORDER BY TEST_DATE DESC) AS rn
    FROM lab_results
    WHERE LOINC_CODE = '4548-4'
      AND TEST_DATE >= DATEADD(day, -365, '2017-12-31') AND TEST_DATE <= '2017-12-31'
),
RankedGFR AS (
    SELECT PATIENT_ID, TRY_CAST(RESULT_VALUE AS DECIMAL(10,2)) AS RESULT_NUM,
           ROW_NUMBER() OVER (PARTITION BY PATIENT_ID ORDER BY TEST_DATE DESC) AS gfr
    FROM lab_results
    WHERE LOINC_CODE = '33914-3'
      AND TEST_DATE >= DATEADD(day, -365, '2017-12-31') AND TEST_DATE <= '2017-12-31'
)
SELECT p.STATE,
       COUNT(*)                        AS ELIGIBLE_PATIENTS,
       FLOOR(COUNT(*) * 0.20)          AS PROJECTED_ENROLMENT
FROM patients p
JOIN RankedLabs a ON a.PATIENT_ID = p.PATIENT_ID AND a.rn  = 1
JOIN RankedGFR  g ON g.PATIENT_ID = p.PATIENT_ID AND g.gfr = 1
WHERE p.BIRTHDATE <= DATEADD(year, -18, '2017-12-31')
  AND p.BIRTHDATE >  DATEADD(year, -76, '2017-12-31')
  AND (p.DEATHDATE IS NULL OR p.DEATHDATE > '2017-12-31')
  AND a.RESULT_NUM > 7.5
  AND g.RESULT_NUM BETWEEN 30 AND 60
  AND EXISTS (SELECT 1 FROM conditions c WHERE c.PATIENT_ID = p.PATIENT_ID
              AND (c.DESCRIPTION LIKE '%type 2 diabetes%' OR c.DESCRIPTION LIKE '%type II diabetes%'))
  AND NOT EXISTS (SELECT 1 FROM medications m WHERE m.PATIENT_ID = p.PATIENT_ID
              AND m.DESCRIPTION LIKE '%insulin%'
              AND m.START_DATE <= '2017-12-31'
              AND (m.STOP_DATE IS NULL OR m.STOP_DATE >= DATEADD(day, -90, '2017-12-31')))
GROUP BY p.STATE
ORDER BY ELIGIBLE_PATIENTS DESC;


/* -------------------------------------------------------------
   EXPECTED RESULT: 0 eligible patients.

   That is the finding, not a bug. Verified stepwise:
     age 18-75 and alive at index ......... 6,823
     latest HbA1c > 7.5 ...................     4
     latest eGFR 30-60 ....................    90
     both laboratory criteria .............     0

   The two lab criteria are individually satisfiable but do not
   intersect. The cohort is already empty before the insulin
   exclusion is applied, so criterion 6 is not the binding one.

   Reported to a medical monitor, the useful sentence is:
   "The HbA1c threshold is the constraint. Four patients clear it,
    ninety clear renal function, and no patient clears both."
   ------------------------------------------------------------- */
