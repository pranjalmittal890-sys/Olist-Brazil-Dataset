-- =====================================================================
-- CLEAN LAYER: orders
-- Source: olist_raw.orders ONLY (single-table dependency by design --
--          clean layer must be independently buildable and rebuildable
--          without depending on any other table's cleaning status).
-- Purpose: Row-level data quality corrections and flags derived purely
--          from columns native to this table. No cross-table joins.
--          No fabrication of missing values. No row removal.
-- Note:    Cross-table facts (e.g. "does this order have line items,"
--          "does this order have a payment record") are explicitly OUT
--          OF SCOPE here -- those are relationship facts that belong at
--          the serving/mart layer, where orders naturally joins to
--          order_items and order_payments. Keeping them out of this
--          script preserves single-source lineage for olist_clean.orders.
-- =====================================================================

CREATE OR REPLACE TABLE `olist-analytics-500708.olist_clean.orders` AS

WITH standardized AS (

  SELECT
    -- Primary key: unique per profiling (99,441 = 99,441). No dedup needed.
    order_id,
    customer_id,

    -- Standardize order_status defensively. Profiling found raw values
    -- were already clean lowercase strings; TRIM/LOWER applied as a
    -- zero-risk formality to guarantee safe grouping/joins downstream.
    LOWER(TRIM(order_status)) AS order_status,

    -- Explicit timestamp casting. Profiling confirmed 0 unparseable
    -- timestamps -- this is a type-safety formality, not a correction.
    CAST(order_purchase_timestamp AS TIMESTAMP)        AS order_purchase_timestamp,
    CAST(order_approved_at AS TIMESTAMP)                AS order_approved_at,
    CAST(order_delivered_carrier_date AS TIMESTAMP)     AS order_delivered_carrier_date,
    CAST(order_delivered_customer_date AS TIMESTAMP)    AS order_delivered_customer_date,
    CAST(order_estimated_delivery_date AS TIMESTAMP)    AS order_estimated_delivery_date

  FROM `olist-analytics-500708.olist_raw.orders`

),

flagged AS (

  SELECT
    s.*,

    -- FLAG 1: General structural NULL indicator (MNAR pattern).
    -- Profiling finding: NULL delivery timestamps explained by
    -- order_status for the vast majority of cases -- not data loss.
    (s.order_status != 'delivered' AND s.order_delivered_customer_date IS NULL)
        AS is_expected_null_delivery,

    -- FLAG 2: Delivered order missing ONLY the final customer delivery
    -- date, with approval and carrier dates both present. Profiling
    -- finding: 7 of 8 delivered/null-customer-date orders fall here.
    (s.order_status = 'delivered'
     AND s.order_delivered_customer_date IS NULL
     AND s.order_approved_at IS NOT NULL
     AND s.order_delivered_carrier_date IS NOT NULL)
        AS is_delivered_missing_final_date_only,

    -- FLAG 3: Delivered order missing MULTIPLE lifecycle timestamps.
    -- Profiling finding: 1 of 8 has no approval date AND no carrier
    -- date either -- no documented lifecycle trail despite 'delivered'
    -- status. Mutually exclusive from Flag 2 by construction.
    (s.order_status = 'delivered'
     AND s.order_delivered_customer_date IS NULL
     AND NOT (s.order_approved_at IS NOT NULL AND s.order_delivered_carrier_date IS NOT NULL))
        AS is_delivered_missing_multiple_dates_anomaly,

    -- FLAG 4: Delivered order with NULL order_approved_at specifically.
    -- Profiling finding: 14 of 160 null-approval rows are 'delivered'.
    -- Contradicts the general MNAR explanation for this column.
    (s.order_status = 'delivered' AND s.order_approved_at IS NULL)
        AS is_delivered_missing_approval_anomaly,

    -- FLAG 5: Delivered order with NULL order_delivered_carrier_date
    -- specifically. Profiling finding: 2 of 1,783 null-carrier rows are
    -- 'delivered'. Same category of contradiction, different stage.
    (s.order_status = 'delivered' AND s.order_delivered_carrier_date IS NULL)
        AS is_delivered_missing_carrier_anomaly,

    -- FLAG 6: Canceled orders with a non-null delivery date.
    -- Profiling finding: 6 of 625 canceled orders (0.96%).
    (s.order_status = 'canceled' AND s.order_delivered_customer_date IS NOT NULL)
        AS is_canceled_with_delivery_date_anomaly,

    -- FLAG 7: Timestamp ordering anomaly -- customer delivery before
    -- carrier pickup. Profiling finding: 23 orders.
    (s.order_delivered_customer_date IS NOT NULL
     AND s.order_delivered_carrier_date IS NOT NULL
     AND s.order_delivered_customer_date < s.order_delivered_carrier_date)
        AS is_delivery_before_carrier_anomaly,

    -- FLAG 8: Timestamp ordering anomaly -- carrier pickup before
    -- approval. Profiling finding: 1,359 orders.
    (s.order_approved_at IS NOT NULL
     AND s.order_delivered_carrier_date IS NOT NULL
     AND s.order_delivered_carrier_date < s.order_approved_at)
        AS is_carrier_before_approval_anomaly

  FROM standardized s

)

SELECT * FROM flagged;

-- Validatio queries -

-- ---------------------------------------------------------------------
-- V1. Row count comparison -- must match raw exactly (no rows dropped)
-- ---------------------------------------------------------------------
SELECT
  (SELECT COUNT(*) FROM `olist-analytics-500708.olist_raw.orders`)   AS raw_row_count,
  (SELECT COUNT(*) FROM `olist-analytics-500708.olist_clean.orders`) AS clean_row_count;
-- Expected: 99441 = 99441

-- ---------------------------------------------------------------------
-- V2. Primary key uniqueness
-- ---------------------------------------------------------------------
SELECT COUNT(*) AS total_rows, COUNT(DISTINCT order_id) AS distinct_order_ids
FROM `olist-analytics-500708.olist_clean.orders`;
-- Expected: equal values

-- ---------------------------------------------------------------------
-- V3. Null profile -- confirm null rates are IDENTICAL to raw
-- (no imputation performed, so nulls must be unchanged)
-- ---------------------------------------------------------------------
SELECT
  COUNTIF(order_approved_at IS NULL)             AS null_approved_at,      -- expect 160
  COUNTIF(order_delivered_carrier_date IS NULL)  AS null_carrier_date,     -- expect 1783
  COUNTIF(order_delivered_customer_date IS NULL) AS null_customer_date     -- expect 2965
FROM `olist-analytics-500708.olist_clean.orders`;

-- ---------------------------------------------------------------------
-- V4. Standardization check -- order_status values
-- ---------------------------------------------------------------------
SELECT DISTINCT order_status
FROM `olist-analytics-500708.olist_clean.orders`
ORDER BY order_status;
-- Expected: 8 clean lowercase values, no whitespace, no case variants

-- ---------------------------------------------------------------------
-- V5. Domain validation -- order_status matches approved value set
-- ---------------------------------------------------------------------
SELECT order_status, COUNT(*) AS n
FROM `olist-analytics-500708.olist_clean.orders`
WHERE order_status NOT IN
  ('delivered','shipped','canceled','unavailable','invoiced','processing','created','approved')
GROUP BY order_status;
-- Expected: 0 rows returned

-- ---------------------------------------------------------------------
-- V6. Timestamp validation
-- ---------------------------------------------------------------------
SELECT
  COUNTIF(order_purchase_timestamp IS NULL) AS null_purchase_ts,  -- expected 0
  MIN(order_purchase_timestamp) AS min_ts,
  MAX(order_purchase_timestamp) AS max_ts
FROM `olist-analytics-500708.olist_clean.orders`;
-- Expected: 0 nulls; range = 2016-09-04 to 2018-10-17

-- ---------------------------------------------------------------------
-- V7. Flag counts -- confirm every flag matches approved profiling numbers
-- ---------------------------------------------------------------------
SELECT
  COUNTIF(is_delivered_missing_final_date_only)          AS n_missing_final_only,      -- expect 7
  COUNTIF(is_delivered_missing_multiple_dates_anomaly)    AS n_missing_multiple,        -- expect 1
  COUNTIF(is_delivered_missing_approval_anomaly)          AS n_delivered_no_approval,   -- expect 14
  COUNTIF(is_delivered_missing_carrier_anomaly)           AS n_delivered_no_carrier,    -- expect 2
  COUNTIF(is_canceled_with_delivery_date_anomaly)         AS n_canceled_with_delivery,  -- expect 6
  COUNTIF(is_delivery_before_carrier_anomaly)             AS n_delivery_before_carrier, -- expect 23
  COUNTIF(is_carrier_before_approval_anomaly)             AS n_carrier_before_approval  -- expect 1359
FROM `olist-analytics-500708.olist_clean.orders`;

-- ---------------------------------------------------------------------
-- V8. Mutual exclusivity -- Flags 2 and 3 must never both be true
-- ---------------------------------------------------------------------
SELECT COUNT(*) AS overlap_rows
FROM `olist-analytics-500708.olist_clean.orders`
WHERE is_delivered_missing_final_date_only = TRUE
  AND is_delivered_missing_multiple_dates_anomaly = TRUE;
-- Expected: 0

-- ---------------------------------------------------------------------
-- V9. Flag 2 + Flag 3 together must equal the full delivered/null-
-- customer-date population (7 + 1 = 8)
-- ---------------------------------------------------------------------
SELECT
  COUNTIF(is_delivered_missing_final_date_only OR is_delivered_missing_multiple_dates_anomaly) AS combined,
  COUNTIF(order_status = 'delivered' AND order_delivered_customer_date IS NULL) AS raw_baseline
FROM `olist-analytics-500708.olist_clean.orders`;
-- Expected: both values equal 8
select *
from `olist-analytics-500708.olist_clean.order_items`
where order_id in(
select order_id
from `olist-analytics-500708.olist_clean.orders`
where FORMAT_TIMESTAMP('%Y-%m', order_purchase_timestamp)='2018-10'
)
