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

    -- Person-level identifier. Cardinality lower than customer_id by
    -- design -- this is the expected structure, not a defect.
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

multi_address_check AS (
  -- Identify which customer_unique_ids span more than one city or
  -- state across their customer_id rows. Powers Flag 1 below.
  -- This is a WITHIN-TABLE aggregation (customers joined to itself
  -- via GROUP BY), not a cross-table join -- stays in scope for this layer.
  SELECT
    customer_unique_id,
    COUNT(DISTINCT customer_city)  AS distinct_cities,
    COUNT(DISTINCT customer_state) AS distinct_states
  FROM standardized
  GROUP BY customer_unique_id
),

flagged AS (

  SELECT
    s.*,

    -- FLAG 1: This customer_unique_id is associated with more than one
    -- city or state across their order history. Profiling finding:
    -- 122 such customer_unique_ids. Plausible explanation is address
    -- change between orders, but this is NOT independently verifiable
    -- from this table alone -- treated as an assumption, not a fact.
    -- Flagged rather than corrected: there is no reliable basis to
    -- pick one address as "the correct one."
    (m.distinct_cities > 1 OR m.distinct_states > 1)
        AS has_multiple_addresses_on_record

  FROM standardized s
  LEFT JOIN multi_address_check m
    ON s.customer_unique_id = m.customer_unique_id

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
-- V9. Flag count -- confirm matches approved profiling number
-- ---------------------------------------------------------------------
SELECT COUNT(DISTINCT customer_unique_id) AS flagged_customers
FROM `olist-analytics-500708.olist_clean.customers`
WHERE has_multiple_addresses_on_record = TRUE;
-- Expected: 122

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







