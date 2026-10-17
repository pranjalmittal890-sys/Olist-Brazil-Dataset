-- =====================================================================
-- CLEAN LAYER: order_payments
-- Source: olist_raw.order_payments ONLY (single-table dependency by
--          design). No cross-table joins. No fabrication of missing
--          values. No row removal. No aggregation performed here --
--          aggregating payments to order_id grain (e.g. SUM(payment_value)
--          GROUP BY order_id) is a serving/mart-layer concern, since it
--          reshapes grain rather than cleaning the row-level source.
-- =====================================================================

CREATE OR REPLACE TABLE `olist-analytics-500708.olist_clean.order_payments` AS

WITH standardized AS (

  SELECT
    -- Defensive TRIM on order_id, consistent with ID handling in
    -- order_items and orders.
    TRIM(order_id) AS order_id,

    -- Grain component: distinguishes multiple payment rows per order.
    -- No transformation needed -- profiling confirmed this behaves as
    -- expected (split payment methods, not sequence gaps).
    payment_sequential,

    -- Standardize payment_type defensively: TRIM + LOWER. Profiling
    -- found values already clean; this is a zero-risk formality
    -- consistent with order_status handling in orders.
    LOWER(TRIM(payment_type)) AS payment_type,

    -- payment_installments and payment_value: left as-is numerically.
    -- Profiling confirmed no negative values and traced the zero-value/
    -- zero-installment rows to the not_defined/voucher pattern -- not a
    -- defect requiring correction.
    payment_installments,
    payment_value

  FROM `olist-analytics-500708.olist_raw.order_payments`

)

SELECT * FROM standardized;

-- ---------------------------------------------------------------------
-- V1. Row count comparison -- must match raw exactly (no rows dropped)
-- ---------------------------------------------------------------------
SELECT
  (SELECT COUNT(*) FROM `olist-analytics-500708.olist_raw.order_payments`)   AS raw_row_count,
  (SELECT COUNT(*) FROM `olist-analytics-500708.olist_clean.order_payments`) AS clean_row_count;
-- Expected: equal values (103886)

-- ---------------------------------------------------------------------
-- V2. Grain check -- (order_id, payment_sequential) uniqueness
-- ---------------------------------------------------------------------
SELECT
  COUNT(*) AS total_rows,
  COUNT(DISTINCT CONCAT(order_id, '-', CAST(payment_sequential AS STRING))) AS distinct_composite_keys
FROM `olist-analytics-500708.olist_clean.order_payments`;
-- Expected: equal values

-- ---------------------------------------------------------------------
-- V3. Null profile -- must remain 0 across all columns (no imputation)
-- ---------------------------------------------------------------------
SELECT
  COUNTIF(order_id IS NULL)              AS null_order_id,
  COUNTIF(payment_sequential IS NULL)    AS null_sequential,
  COUNTIF(payment_type IS NULL)          AS null_payment_type,
  COUNTIF(payment_installments IS NULL)  AS null_installments,
  COUNTIF(payment_value IS NULL)         AS null_payment_value
FROM `olist-analytics-500708.olist_clean.order_payments`;
-- Expected: all 0

-- ---------------------------------------------------------------------
-- V4. Standardization check -- payment_type domain
-- ---------------------------------------------------------------------
SELECT DISTINCT payment_type
FROM `olist-analytics-500708.olist_clean.order_payments`
ORDER BY payment_type;
-- Expected: clean lowercase values only (credit_card, boleto, voucher,
-- debit_card, not_defined) -- no whitespace/casing variants

-- ---------------------------------------------------------------------
-- V5. Domain validation -- no negative payment values or installments
-- ---------------------------------------------------------------------
SELECT
  COUNTIF(payment_value < 0)        AS negative_payment_value,   -- expect 0
  COUNTIF(payment_installments < 0) AS negative_installments      -- expect 0
FROM `olist-analytics-500708.olist_clean.order_payments`;

-- ---------------------------------------------------------------------
-- V6. Flag counts -- confirm match approved profiling numbers
-- ---------------------------------------------------------------------
SELECT
  COUNTIF(payment_type='not_defined') AS n_undefined_type,   -- expect 3
  COUNTIF(payment_value=0)     AS n_zero_value      -- expect matches profiling baseline
FROM `olist-analytics-500708.olist_clean.order_payments`;

-- ---------------------------------------------------------------------
-- V8. Referential integrity -- order_payments -> clean orders
-- ---------------------------------------------------------------------
SELECT COUNT(*) AS orphan_payments_missing_order
FROM `olist-analytics-500708.olist_clean.order_payments` op
LEFT JOIN `olist-analytics-500708.olist_clean.orders` o
  ON op.order_id = o.order_id
WHERE o.order_id IS NULL;
-- Expected: 0

-- ---------------------------------------------------------------------
-- V9. Payment sequential sanity check -- reconfirm the split-payment-
-- method explanation still holds on the clean table (not re-flagging,
-- just re-validating the profiling conclusion wasn't broken by cleaning)
-- ---------------------------------------------------------------------
SELECT
  order_id,
  COUNT(*) AS payment_rows,
  COUNT(DISTINCT payment_type) AS distinct_payment_types,
  MAX(payment_sequential) AS max_seq
FROM `olist-analytics-500708.olist_clean.order_payments`
GROUP BY order_id
HAVING COUNT(*) != MAX(payment_sequential)
   AND COUNT(DISTINCT payment_type) = 1
LIMIT 20;
-- Expected: 0 rows -- if any appear, these would be TRUE sequence gaps
-- (same payment type, mismatched count vs max sequential), which would
-- contradict the profiling conclusion and require re-investigation

