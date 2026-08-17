-- =====================================================================
-- CLEAN LAYER: order_items
-- Source: olist_raw.order_items ONLY (single-table dependency by design).
-- Purpose: Row-level standardization and flagging derived purely from
--          columns native to this table. No cross-table joins.
--          No fabrication of missing values. No row removal.
-- Note:    RI-2/RI-3/RI-4 (referential integrity against orders,
--          products, sellers) were all confirmed 0 orphans during the
--          RI audit -- a positive finding, documented separately, not
--          represented here since there is no anomaly to flag and no
--          join is needed to confirm a table-native property.
-- =====================================================================

CREATE OR REPLACE TABLE `olist-analytics-500708.olist_clean.order_items` AS

WITH standardized AS (

  SELECT
    -- Composite grain: (order_id, order_item_id). order_item_id restarts
    -- per order by design -- this is expected structure, not a defect.
    TRIM(order_id) AS order_id,
    order_item_id,

    -- Defensive TRIM on ID columns. Profiling found no whitespace/casing
    -- issues on these specifically, but this is a zero-risk formality
    -- applied consistently with how ID columns were handled in the
    -- orders and customers clean tables.
    TRIM(product_id) AS product_id,
    TRIM(seller_id)  AS seller_id,

    -- Explicit timestamp cast. Profiling confirmed this column parses
    -- cleanly with no unparseable values -- type-safety formality only.
    CAST(shipping_limit_date AS TIMESTAMP) AS shipping_limit_date,

    -- price and freight_value: left as-is numerically. Profiling
    -- confirmed 0 negative values and 0 zero-price rows. No
    -- transformation applied -- skew is a distributional property,
    -- not a data quality issue, and does not belong in this layer.
    price,
    freight_value

  FROM `olist-analytics-500708.olist_raw.order_items`

),

flagged AS (

  SELECT
    s.*,

    -- FLAG 1: freight_value = 0. Profiling finding: 383 rows. Plausibly
    -- legitimate (free-shipping promotion), not proven to be an error.
    -- Flagged so downstream logic can isolate or include these
    -- deliberately rather than silently treating $0 freight as normal
    -- or as an error without a documented basis either way.
    (s.freight_value = 0)
        AS is_zero_freight,

    -- FLAG 2: shipping_limit_date anomaly. Profiling finding: 4 rows,
    -- all isolated to a single seller_id, with dates ~3 years past the
    -- corresponding order's purchase timestamp. Root cause isolated to
    -- that seller but not correctable -- no reliable true date exists.
    -- Threshold: dates on/after 2019-01-01 were confirmed in profiling
    -- to isolate exactly this anomalous cohort (dataset's true max
    -- purchase date is 2018-10-17, so any shipping_limit_date this far
    -- past it is implausible).
    (s.shipping_limit_date >= TIMESTAMP('2019-01-01'))
        AS is_shipping_date_anomaly

  FROM standardized s

)

SELECT * FROM flagged;

-- ---------------------------------------------------------------------
-- V1. Row count comparison -- must match raw exactly (no rows dropped)
-- ---------------------------------------------------------------------
SELECT
  (SELECT COUNT(*) FROM `olist-analytics-500708.olist_raw.order_items`)   AS raw_row_count,
  (SELECT COUNT(*) FROM `olist-analytics-500708.olist_clean.order_items`) AS clean_row_count;
-- Expected: equal values (112650)

-- ---------------------------------------------------------------------
-- V2. Composite key uniqueness -- (order_id, order_item_id)
-- ---------------------------------------------------------------------
SELECT
  COUNT(*) AS total_rows,
  COUNT(DISTINCT CONCAT(order_id, '-', CAST(order_item_id AS STRING))) AS distinct_composite_keys
FROM `olist-analytics-500708.olist_clean.order_items`;
-- Expected: equal values

-- ---------------------------------------------------------------------
-- V3. Null profile -- must remain 0 across all columns (no imputation)
-- ---------------------------------------------------------------------
SELECT
  COUNTIF(order_id IS NULL)             AS null_order_id,
  COUNTIF(product_id IS NULL)           AS null_product_id,
  COUNTIF(seller_id IS NULL)            AS null_seller_id,
  COUNTIF(price IS NULL)                AS null_price,
  COUNTIF(freight_value IS NULL)        AS null_freight,
  COUNTIF(shipping_limit_date IS NULL)  AS null_ship_date
FROM `olist-analytics-500708.olist_clean.order_items`;
-- Expected: all 0

-- ---------------------------------------------------------------------
-- V4. Domain validation -- no negative price/freight introduced or missed
-- ---------------------------------------------------------------------
SELECT
  COUNTIF(price < 0)          AS negative_price,   -- expect 0
  COUNTIF(freight_value < 0)  AS negative_freight,  -- expect 0
  COUNTIF(price = 0)          AS zero_price         -- expect 0
FROM `olist-analytics-500708.olist_clean.order_items`;

-- ---------------------------------------------------------------------
-- V5. Flag counts -- confirm match approved profiling numbers
-- ---------------------------------------------------------------------
SELECT
  COUNTIF(is_zero_freight)          AS n_zero_freight,           -- expect 383
  COUNTIF(is_shipping_date_anomaly) AS n_shipping_date_anomaly    -- expect 4
FROM `olist-analytics-500708.olist_clean.order_items`;

-- ---------------------------------------------------------------------
-- V6. Timestamp validation
-- ---------------------------------------------------------------------
SELECT
  COUNTIF(shipping_limit_date IS NULL) AS null_ts,  -- expect 0
  MIN(shipping_limit_date) AS min_ts,
  MAX(shipping_limit_date) AS max_ts
FROM `olist-analytics-500708.olist_clean.order_items`;
-- Expected: 0 nulls; max_ts should reflect the known anomaly (~2020)

-- ---------------------------------------------------------------------
-- V7. Referential integrity -- order_items -> clean orders
-- (re-confirm against the CLEAN orders table, not raw, now that it exists)
-- ---------------------------------------------------------------------
SELECT COUNT(*) AS orphan_items_missing_order
FROM `olist-analytics-500708.olist_clean.order_items` oi
LEFT JOIN `olist-analytics-500708.olist_clean.orders` o
  ON oi.order_id = o.order_id
WHERE o.order_id IS NULL;
-- Expected: 0

-- ---------------------------------------------------------------------
-- V8. Referential integrity -- order_items -> raw products/sellers
-- (products and sellers clean tables don't exist yet -- validate against
-- raw for now; re-run against clean versions once built)
-- ---------------------------------------------------------------------
SELECT
  (SELECT COUNT(*) FROM `olist-analytics-500708.olist_clean.order_items` oi
   LEFT JOIN `olist-analytics-500708.olist_raw.products` p ON oi.product_id = p.product_id
   WHERE p.product_id IS NULL) AS orphan_items_missing_product,

  (SELECT COUNT(*) FROM `olist-analytics-500708.olist_clean.order_items` oi
   LEFT JOIN `olist-analytics-500708.olist_raw.sellers` s ON oi.seller_id = s.seller_id
   WHERE s.seller_id IS NULL) AS orphan_items_missing_seller;
-- Expected: 0 and 0

-- ---------------------------------------------------------------------
-- V9. Isolate the shipping_limit_date anomaly to the single known seller
-- (confirms the anomaly is still scoped exactly as profiling found it)
-- ---------------------------------------------------------------------
SELECT DISTINCT seller_id
FROM `olist-analytics-500708.olist_clean.order_items`
WHERE is_shipping_date_anomaly = TRUE;
-- Expected: exactly 1 distinct seller_id, matching the seller identified in profiling




