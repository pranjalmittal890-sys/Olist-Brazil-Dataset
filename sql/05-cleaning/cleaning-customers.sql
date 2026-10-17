-- =====================================================================
-- CLEAN LAYER: customers
-- Source: olist_raw.customers ONLY (single-table dependency by design).
-- Purpose: Row-level standardization and flagging derived purely from
--          columns native to this table. No cross-table joins.
--          No fabrication of missing values. No row removal.
-- Note:    RI-11 (customer zip codes with no matching geolocation
--          record) is a cross-table fact and explicitly OUT OF SCOPE
--          here -- it belongs at the serving/mart layer where customers
--          naturally joins to geolocation. Documented in the RI audit.
-- =====================================================================

CREATE OR REPLACE TABLE `olist-analytics-500708.olist_clean.customers` AS

WITH standardized AS (

  SELECT
    -- Order-level surrogate key. Unique per profiling (99,441 = 99,441).
    customer_id,

    customer_unique_id,

    -- Zip code prefix: cast to STRING and zero-pad to 5 digits.
    -- Profiling found no structurally invalid values (no negatives,
    -- sane min/max), but BigQuery may store this as INT64, which
    -- silently drops leading zeros (e.g. 01310 -> 1310). Zero-padding
    -- defensively protects any future join to geolocation.zip_code or
    -- sellers.zip_code from silent mismatches caused by type handling,
    -- not from any defect found in the source values themselves.
    LPAD(CAST(customer_zip_code_prefix AS STRING), 5, '0') AS customer_zip_code_prefix,

    -- Standardize city defensively: TRIM + LOWER for consistent casing
    -- and no leading/trailing whitespace. Profiling did NOT find
    -- diacritic/normalization issues specific to this column (that
    -- finding was scoped to the geolocation table) -- so no further
    -- normalization is applied here without table-specific evidence.
    LOWER(TRIM(customer_city)) AS customer_city,

    -- Standardize state defensively: TRIM + UPPER for consistent
    -- 2-letter code casing. Profiling confirmed 27 valid distinct
    -- values (26 states + DF) -- this is a formality, not a correction.
    UPPER(TRIM(customer_state)) AS customer_state

  FROM `olist-analytics-500708.olist_raw.customers`

),

-- Evidenced typo/formatting corrections, derived from zip-prefix
-- majority-pattern triage. Deterministic substitution only.
correction_lookup AS (
  SELECT * FROM UNNEST([
    STRUCT('dias d avila' AS incorrect_value, "dias d'avila" AS correct_value),
    STRUCT('arraial d ajuda', "arraial d'ajuda"),
    STRUCT('itapage', 'itapaje'),
    STRUCT('planaltina de goias', 'planaltina'),
    STRUCT('brasopolis', 'brazopolis'),
    STRUCT('piumhi', 'piumhii'),
    STRUCT('bataipora', 'bataypora'),
    STRUCT('palmeira d oeste', "palmeira d'oeste"),
    STRUCT('estrela d oeste', "estrela d'oeste"),
    STRUCT('mogi-mirim', 'mogi mirim'),
    STRUCT('santa barbara d oeste', "santa barbara d'oeste"),
    STRUCT('embu', 'embu das artes'),
    STRUCT('picarras', 'balneario picarras'),
    STRUCT('parati', 'paraty'),
    STRUCT('vitoria', 'colonia vitoria'),
    struct('sao jorge do oeste', "sao jorge d'oeste")
  ])
),

flagged AS (

  SELECT
    s.customer_id,
    s.customer_unique_id,
    s.customer_zip_code_prefix,
  COALESCE(cl.correct_value, s.customer_city) AS customer_city,
  s.customer_state,
  (cl.correct_value IS NOT NULL) AS city_was_corrected
  FROM standardized s
  LEFT JOIN correction_lookup cl
    ON s.customer_city = cl.incorrect_value

)

SELECT * FROM flagged;

-- ---------------------------------------------------------------------
-- V1. Row count comparison -- must match raw exactly (no rows dropped)
-- ---------------------------------------------------------------------
SELECT
  (SELECT COUNT(*) FROM `olist-analytics-500708.olist_raw.customers`)   AS raw_row_count,
  (SELECT COUNT(*) FROM `olist-analytics-500708.olist_clean.customers`) AS clean_row_count;
-- Expected: 99441 = 99441

-- ---------------------------------------------------------------------
-- V2. Primary key uniqueness -- customer_id
-- ---------------------------------------------------------------------
SELECT COUNT(*) AS total_rows, COUNT(DISTINCT customer_id) AS distinct_customer_id
FROM `olist-analytics-500708.olist_clean.customers`;
-- Expected: equal values (99441 = 99441)

-- ---------------------------------------------------------------------
-- V3. customer_unique_id cardinality -- confirm ratio unchanged from raw
-- ---------------------------------------------------------------------
SELECT
  COUNT(DISTINCT customer_id)        AS uniq_customer_id,
  COUNT(DISTINCT customer_unique_id) AS uniq_person
FROM `olist-analytics-500708.olist_clean.customers`;
-- Expected: matches raw profiling baseline exactly (99441 / ~96096)

-- ---------------------------------------------------------------------
-- V4. Null profile -- must remain 0 across all columns (no imputation)
-- ---------------------------------------------------------------------
SELECT
  COUNTIF(customer_id IS NULL)              AS null_customer_id,
  COUNTIF(customer_unique_id IS NULL)       AS null_unique_id,
  COUNTIF(customer_zip_code_prefix IS NULL) AS null_zip,
  COUNTIF(customer_city IS NULL)            AS null_city,
  COUNTIF(customer_state IS NULL)           AS null_state
FROM `olist-analytics-500708.olist_clean.customers`;
-- Expected: all 0

-- ---------------------------------------------------------------------
-- V5. Standardization check -- customer_state domain
-- ---------------------------------------------------------------------
SELECT DISTINCT customer_state
FROM `olist-analytics-500708.olist_clean.customers`
ORDER BY customer_state;
-- Expected: 27 clean uppercase 2-letter codes

-- ---------------------------------------------------------------------
-- V6. Domain validation -- customer_state matches valid Brazil state set
-- ---------------------------------------------------------------------
SELECT customer_state, COUNT(*) AS n
FROM `olist-analytics-500708.olist_clean.customers`
WHERE customer_state NOT IN (
  'AC','AL','AP','AM','BA','CE','DF','ES','GO','MA','MT','MS','MG',
  'PA','PB','PR','PE','PI','RJ','RN','RS','RO','RR','SC','SP','SE','TO'
)
GROUP BY customer_state;
-- Expected: 0 rows returned

-- ---------------------------------------------------------------------
-- V7. Zip code format check -- confirm 5-digit zero-padded string
-- ---------------------------------------------------------------------
SELECT COUNT(*) AS malformed_zips
FROM `olist-analytics-500708.olist_clean.customers`
WHERE LENGTH(customer_zip_code_prefix) != 5
   OR NOT REGEXP_CONTAINS(customer_zip_code_prefix, r'^[0-9]{5}$');
-- Expected: 0

-- ---------------------------------------------------------------------
-- V8. City standardization check -- no leading/trailing whitespace,
-- no uppercase remnants
-- ---------------------------------------------------------------------
SELECT COUNT(*) AS unstandardized_city_rows
FROM `olist-analytics-500708.olist_clean.customers`
WHERE customer_city != LOWER(TRIM(customer_city));
-- Expected: 0

-- ---------------------------------------------------------------------
-- V9. multiple cities typo - 15 left
-- ---------------------------------------------------------------------
SELECT
customer_zip_code_prefix,
ARRAY_AGG(DISTINCT customer_city ORDER BY customer_city) AS cities,
-- COUNT(*) AS sellers
ARRAY_AGG(DISTINCT customer_state ORDER BY customer_state) AS states,
FROM `olist-analytics-500708.olist_clean.customers`
GROUP BY customer_zip_code_prefix
HAVING COUNT(DISTINCT customer_city) > 1;
-- Expected: <39 as many were corrected

-- Correction count -- confirm matches the number of pairs you
-- populate in correction_lookup - 425
SELECT COUNT(*) AS corrected_rows
FROM `olist-analytics-500708.olist_clean.customers`
WHERE city_was_corrected = TRUE;

-- count of affected rows is reasonable (some typos may repeat across customers) - 425
SELECT COUNT(*) AS corrected_rows
FROM `olist-analytics-500708.olist_clean.customers`
WHERE city_was_corrected = TRUE;

-- ---------------------------------------------------------------------
-- V10. Referential integrity -- customers <- orders (reverse of RI-1,
-- already confirmed 0 orphans from the orders side; re-confirm here
-- for completeness now that customers has its own clean version)
-- ---------------------------------------------------------------------
SELECT COUNT(*) AS orphan_orders_missing_customer
FROM `olist-analytics-500708.olist_clean.orders` o
LEFT JOIN `olist-analytics-500708.olist_clean.customers` c
  ON o.customer_id = c.customer_id
WHERE c.customer_id IS NULL;
-- Expected: 0







