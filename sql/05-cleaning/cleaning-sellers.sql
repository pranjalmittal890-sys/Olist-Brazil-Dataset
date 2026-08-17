-- =====================================================================
-- CLEAN LAYER: sellers (FINAL)
-- Source: olist_raw.sellers ONLY (single-table dependency by design).
-- Correction lookup below is derived directly from manual triage
-- against zip-prefix majority patterns (see profiling documentation).
-- =====================================================================

CREATE OR REPLACE TABLE `olist-analytics-500708.olist_clean.sellers` AS

WITH standardized AS (

  SELECT
    TRIM(seller_id) AS seller_id,
    LPAD(CAST(seller_zip_code_prefix AS STRING), 5, '0') AS seller_zip_code_prefix,
    LOWER(TRIM(seller_city)) AS seller_city_normalized,
    UPPER(TRIM(seller_state)) AS seller_state

  FROM `olist-analytics-500708.olist_raw.sellers`

),

-- Evidenced typo/formatting corrections, derived from zip-prefix
-- majority-pattern triage. Deterministic substitution only.
correction_lookup AS (
  SELECT * FROM UNNEST([
    STRUCT('sao paulo sp' AS incorrect_value, 'sao paulo' AS correct_value),
    STRUCT('garulhos', 'guarulhos'),
    STRUCT('mogi das cruses', 'mogi das cruzes'),
    STRUCT('sando andre', 'santo andre'),
    STRUCT('santo andre/sao paulo', 'santo andre'),
    STRUCT('maua/sao paulo', 'maua'),
    STRUCT('sao bernardo do capo', 'sao bernardo do campo'),
    STRUCT('santa barbara d oeste', "santa barbara d'oeste"),
    STRUCT('portoferreira', 'porto ferreira'),
    STRUCT('scao jose do rio pardo', 'sao jose do rio pardo'),
    STRUCT('robeirao preto', 'ribeirao preto'),
    STRUCT('ribeirao preto / sao paulo', 'ribeirao preto'),
    STRUCT('riberao preto', 'ribeirao preto'),
    STRUCT('auriflama/sp', 'auriflama'),
    STRUCT('rio de janeiro, rio de janeiro, brasil', 'rio de janeiro'),
    STRUCT('belo horizont', 'belo horizonte'),
    STRUCT('cascavael', 'cascavel'),
    STRUCT('floranopolis', 'florianopolis'),
    STRUCT('balenario camboriu', 'balneario camboriu'),
    STRUCT('lages - sc', 'lages'),
    STRUCT('sao miguel do oeste', "sao miguel d'oeste"),
    STRUCT('vendas@creditparts.com.br', 'maringa'),   -- 3-of-4 majority at zip 87025
    STRUCT('parana', 'maringa'),                        -- 3-of-4 majority at zip 87083
    STRUCT('04482255','rio de janeiro')             -- 4-of-5 majority at zip 22790
  ])
),

corrected AS (

  SELECT
    s.seller_id,
    s.seller_zip_code_prefix,
    COALESCE(cl.correct_value, s.seller_city_normalized) AS seller_city,
    s.seller_state,
    (cl.correct_value IS NOT NULL) AS city_was_corrected

  FROM standardized s
  LEFT JOIN correction_lookup cl
    ON s.seller_city_normalized = cl.incorrect_value

),

flagged AS (

  SELECT
    c.*,

    -- FLAG: wrong-attribute entry -- city field contains something
    -- structurally not a city name (email, numeric code, or a state
    -- name/abbreviation). Confirmed via manual triage: 6 cases.
    -- Includes 'parana' and the creditparts email, both moved here
    -- from an initial "clean" classification for consistency with how
    -- the numeric-code and 'sp'-only cases were already handled --
    -- majority-value agreement doesn't justify correcting a value that
    -- was never a city name attempt in the first place.
    (c.seller_city IN (
        'sp',
        'minas gerais',
        'santa catarina'
    ))
        AS has_wrong_attribute_city

  FROM corrected c

)

SELECT * FROM flagged;

-- V1. Row count comparison
SELECT
  (SELECT COUNT(*) FROM `olist-analytics-500708.olist_raw.sellers`)   AS raw_row_count,
  (SELECT COUNT(*) FROM `olist-analytics-500708.olist_clean.sellers`) AS clean_row_count;
-- Expected: equal values

-- V2. Primary key uniqueness
SELECT COUNT(*) AS total_rows, COUNT(DISTINCT seller_id) AS distinct_seller_ids
FROM `olist-analytics-500708.olist_clean.sellers`;
-- Expected: equal values

-- V3. Null profile -- must remain 0 (no imputation performed)
SELECT
  COUNTIF(seller_zip_code_prefix IS NULL) AS null_zip,
  COUNTIF(seller_city IS NULL)            AS null_city,
  COUNTIF(seller_state IS NULL)           AS null_state
FROM `olist-analytics-500708.olist_clean.sellers`;
-- Expected: all 0

-- V4. Zip format check -- confirm 5-digit zero-padded string
SELECT COUNT(*) AS malformed_zips
FROM `olist-analytics-500708.olist_clean.sellers`
WHERE LENGTH(seller_zip_code_prefix) != 5
   OR NOT REGEXP_CONTAINS(seller_zip_code_prefix, r'^[0-9]{5}$');
-- Expected: 0

-- V5. Correction count -- confirm matches the number of pairs you
-- populate in correction_lookup (update expected value once filled in)
SELECT COUNT(*) AS corrected_rows
FROM `olist-analytics-500708.olist_clean.sellers`
WHERE city_was_corrected = TRUE;
-- Expected: matches count of rows actually affected by your lookup pairs
-- (not necessarily = number of lookup pairs, if a typo appears on
-- multiple seller rows)

-- V6. Wrong-attribute flag -- confirm count is in the expected range
-- from profiling (~5), and manually review the flagged rows to confirm
-- the regex caught the right ones
SELECT seller_id, seller_city, seller_state
FROM `olist-analytics-500708.olist_clean.sellers`
WHERE has_wrong_attribute_city = TRUE;
-- Manually cross-check against your profiling triage list

-- V8. Post-correction duplicate check -- re-run the original profiling
-- duplicate-detection logic against the CLEAN table to confirm typo/
-- formatting corrections actually reduced the duplicate zip->city
-- pattern (should show fewer cases than the raw-table version)
SELECT
  seller_zip_code_prefix,
  array_agg(distinct seller_city order by seller_city) as cities,
  COUNT(DISTINCT seller_city) AS distinct_cities
FROM `olist-analytics-500708.olist_clean.sellers`
GROUP BY seller_zip_code_prefix
HAVING COUNT(DISTINCT seller_city) > 1;
-- Expected: fewer rows than the raw-table equivalent query; remaining
-- rows should be exactly the wrong-attribute and ambiguous cases
-- 10 zip codes with 2 cities but different now

-- V9. Referential integrity -- order_items -> clean sellers
SELECT COUNT(*) AS orphan_items_missing_seller
FROM `olist-analytics-500708.olist_clean.order_items` oi
LEFT JOIN `olist-analytics-500708.olist_clean.sellers` s
  ON oi.seller_id = s.seller_id
WHERE s.seller_id IS NULL;
-- Expected: 0

-- V5b. Confirm exactly 24 correction pairs are represented, and count
-- of affected rows is reasonable (some typos may repeat across sellers)
SELECT COUNT(*) AS corrected_rows
FROM `olist-analytics-500708.olist_clean.sellers`
WHERE city_was_corrected = TRUE;

-- V6b. Confirm wrong-attribute flag count = 3 distinct value-patterns
-- (row count may be higher if a pattern like 'sp' appears on multiple
-- seller rows) then it is 6
SELECT seller_city, COUNT(*) AS n
FROM `olist-analytics-500708.olist_clean.sellers`
WHERE has_wrong_attribute_city = TRUE
GROUP BY seller_city
ORDER BY n DESC;





