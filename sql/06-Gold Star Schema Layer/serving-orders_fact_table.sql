-- =====================================================================
-- serving LAYER: fact_order_item_fulfillment
-- Source: olist_clean.order_items, olist_clean.orders,
--          olist_clean.order_reviews (Clean Layer only)
-- Grain: one row per order item (order_id, order_item_id).
-- No payment information included, per approved scope.
-- =====================================================================

CREATE OR REPLACE TABLE `olist-analytics-500708.olist_serving.fact_order_item_fulfillment` AS

WITH most_recent_review AS (
  -- Resolve multi-review orders to a single review before joining.
  -- "Most recent wins" -- consistent with the same recency rule
  -- already applied to dim_customer's address fields, rather than an
  -- arbitrary one-off choice for this table.
  SELECT
    order_id,
    review_score,
    ROW_NUMBER() OVER (
      PARTITION BY order_id
      ORDER BY review_creation_date DESC
    ) AS review_recency_rank
  FROM `olist-analytics-500708.olist_clean.order_reviews`
),

review_resolved AS (
  SELECT order_id, review_score
  FROM most_recent_review
  WHERE review_recency_rank = 1
),

order_level_attributes AS (
  -- Pre-compute all order-level derived measures ONCE per order,
  -- before joining to order_items. This avoids recomputing the same
  -- TIMESTAMP_DIFF / boolean logic redundantly for every item row of
  -- a multi-item order -- same result either way, but computed once
  -- here is cleaner and cheaper.
  SELECT
    o.order_id,
    o.customer_id,
    o.order_status,
    DATE(o.order_purchase_timestamp) AS order_purchase_date,

    TIMESTAMP_DIFF(o.order_delivered_carrier_date, o.order_approved_at, HOUR)
      AS approval_to_carrier_hours,

    TIMESTAMP_DIFF(o.order_delivered_customer_date, o.order_delivered_carrier_date, DAY)
      AS carrier_to_customer_days,

    -- is_delivered_on_time: explicitly NULL when order_delivered_customer_date
    -- is NULL. The comparison itself naturally produces NULL in this
    -- case (NULL <= anything evaluates to NULL, not FALSE, in standard
    -- SQL) -- no COALESCE is applied, preserving that behavior
    -- deliberately rather than accidentally.
    CASE
      WHEN o.order_delivered_customer_date IS NULL THEN NULL
      ELSE o.order_delivered_customer_date <= o.order_estimated_delivery_date
    END AS is_delivered_on_time,

    -- NEW (additive): magnitude of the delivery miss, in whole days.
    -- Positive = delivered this many days AFTER the promised date (late).
    -- Negative = delivered this many days BEFORE the promised date (early).
    -- 0 = delivered on the promised calendar day.
    -- NULL = never delivered -- same NULL rule as is_delivered_on_time,
    -- never coerced to 0.
    CASE
      WHEN o.order_delivered_customer_date IS NULL THEN NULL
      ELSE DATE_DIFF(
             DATE(o.order_delivered_customer_date),
             DATE(o.order_estimated_delivery_date),
             DAY)
    END AS delivery_estimate_error_days,

    -- Rolled-up anomaly summary across all seven Silver-layer order-
    -- level flags (six of the seven map to the approved junk
    -- dimension; this boolean is independent of that dimension and
    -- exists for fast filtering without a dimension join).
    (
      o.is_delivery_before_carrier_anomaly
      OR o.is_delivered_missing_approval_anomaly
      OR o.is_delivered_missing_multiple_dates_anomaly
      OR o.is_carrier_before_approval_anomaly
      OR o.is_canceled_with_delivery_date_anomaly
    ) AS has_order_level_anomaly,

    -- Carry the raw flags forward for the junk dimension join below --
    -- not selected into the final output directly.
    o.is_delivery_before_carrier_anomaly,
    o.is_delivered_missing_approval_anomaly,
    o.is_delivered_missing_multiple_dates_anomaly,
    o.is_carrier_before_approval_anomaly,
    o.is_canceled_with_delivery_date_anomaly

  FROM `olist-analytics-500708.olist_clean.orders` o
),

customer_lookup AS (
  -- Resolve order.customer_id (order-level key) to the serving layer's
  -- person-level customer_key. Two-hop: customer_id -> customer_unique_id
  -- (via Silver customers) -> customer_key (via dim_customer).
  SELECT
    c.customer_id,
    dc.customer_key
  FROM `olist-analytics-500708.olist_clean.customers` c
  INNER JOIN `olist-analytics-500708.olist_serving.dim_customer` dc
    ON c.customer_unique_id = dc.customer_unique_id
)

SELECT
  -- Surrogate key.
  ROW_NUMBER() OVER (ORDER BY oi.order_id, oi.order_item_id) AS order_item_key,

  oi.order_id,
  oi.order_item_id,

  cl.customer_key,
  ds.seller_key,
  dp.product_key,
  dd.date_key AS order_date_key,
  dqf.data_quality_key,

  oi.price,
  oi.freight_value,

  -- SAFE_DIVIDE per requirement -- returns NULL instead of erroring on
  -- price = 0 (Silver confirmed 0 such rows exist currently, but
  -- SAFE_DIVIDE is used defensively regardless, not assuming that
  -- invariant holds forever).
  SAFE_DIVIDE(oi.freight_value, oi.price) AS freight_to_price_ratio,

  ola.approval_to_carrier_hours,
  ola.carrier_to_customer_days,
  ola.is_delivered_on_time,
  ola.delivery_estimate_error_days,   -- NEW

  rr.review_score,
  (rr.review_score IS NOT NULL) AS has_review,

  -- Full has_fulfillment_anomaly: order-level rollup OR the item-native
  -- shipping anomaly. This is broader than order_level_attributes'
  -- has_order_level_anomaly, which deliberately excludes the shipping
  -- flag since that CTE operates before the join to order_items.
  (ola.has_order_level_anomaly OR oi.is_shipping_date_anomaly) AS has_fulfillment_anomaly,

  ola.order_status

FROM `olist-analytics-500708.olist_clean.order_items` oi

INNER JOIN order_level_attributes ola
  ON oi.order_id = ola.order_id

LEFT JOIN customer_lookup cl
  ON ola.customer_id = cl.customer_id

LEFT JOIN `olist-analytics-500708.olist_serving.dim_seller` ds
  ON oi.seller_id = ds.seller_id

LEFT JOIN `olist-analytics-500708.olist_serving.dim_product` dp
  ON oi.product_id = dp.product_id

LEFT JOIN `olist-analytics-500708.olist_serving.dim_date` dd
  ON ola.order_purchase_date = dd.full_date

LEFT JOIN review_resolved rr
  ON oi.order_id = rr.order_id

LEFT JOIN `olist-analytics-500708.olist_serving.data_quality_flags` dqf
  ON ola.is_delivery_before_carrier_anomaly = dqf.is_delivery_before_carrier_anomaly
  AND ola.is_delivered_missing_approval_anomaly = dqf.is_delivered_missing_approval_anomaly
  AND ola.is_delivered_missing_multiple_dates_anomaly = dqf.is_delivered_missing_multiple_dates_anomaly
  AND ola.is_carrier_before_approval_anomaly = dqf.is_carrier_before_approval_anomaly
  AND ola.is_canceled_with_delivery_date_anomaly = dqf.is_canceled_with_delivery_date_anomaly
  AND oi.is_shipping_date_anomaly = dqf.is_shipping_anomaly;


-- V1. Row count -- must exactly match olist_clean.order_items
SELECT
  (SELECT COUNT(*) FROM `olist-analytics-500708.olist_clean.order_items`) AS silver_count,
  (SELECT COUNT(*) FROM `olist-analytics-500708.olist_serving.fact_order_item_fulfillment`) AS serving_count;
-- Expected: equal

-- V2. NULL rule -- the new column must be NULL on EXACTLY the same rows
-- where is_delivered_on_time is NULL (both driven by a missing delivery date).
SELECT COUNTIF( (delivery_estimate_error_days IS NULL) != (is_delivered_on_time IS NULL) ) AS null_mismatch
FROM `olist-analytics-500708.olist_serving.fact_order_item_fulfillment`;
-- Expected: 0

-- V3. Sign consistency -- the two impossible combinations must never occur.
SELECT
  COUNTIF(delivery_estimate_error_days > 0 AND is_delivered_on_time = TRUE)  AS late_but_flagged_ontime,
  COUNTIF(delivery_estimate_error_days < 0 AND is_delivered_on_time = FALSE) AS early_but_flagged_late
FROM `olist-analytics-500708.olist_serving.fact_order_item_fulfillment`;
-- Expected: both 0

-- V4. The one explainable edge case -- delivered ON the promised calendar
-- day (error = 0) but flagged FALSE, because the estimate is stored at
-- midnight and the parcel arrived later that same day. This is expected
-- and correct, NOT a bug -- report the count so it is understood, not hidden.
SELECT COUNTIF(delivery_estimate_error_days = 0 AND is_delivered_on_time = FALSE) AS same_day_boundary_rows
FROM `olist-analytics-500708.olist_serving.fact_order_item_fulfillment`;
-- Expected: a small, non-zero number is fine and explainable.

-- V5. Denormalization consistency -- the value must be identical across
-- all item rows of the same order (it is an order-level fact).
SELECT COUNT(*) AS orders_with_inconsistent_error
FROM (
  SELECT order_id
  FROM `olist-analytics-500708.olist_serving.fact_order_item_fulfillment`
  GROUP BY order_id
  HAVING COUNT(DISTINCT delivery_estimate_error_days) > 1
);
-- Expected: 0

-- V6. Business sanity -- distribution of the miss. Olist estimates are
-- known to be padded/conservative, so most deliveries should land EARLY
-- (negative), with a smaller late tail.
SELECT
  MIN(delivery_estimate_error_days) AS most_early,
  MAX(delivery_estimate_error_days) AS most_late,
  APPROX_QUANTILES(delivery_estimate_error_days, 4) AS quartiles
FROM `olist-analytics-500708.olist_serving.fact_order_item_fulfillment`
WHERE delivery_estimate_error_days IS NOT NULL;
-- Manually review: median should be negative (delivered early on average).

-- V2. Duplicate validation -- composite natural key and surrogate key
SELECT
  COUNT(*) AS total_rows,
  COUNT(DISTINCT order_item_key) AS distinct_surrogate_keys,
  COUNT(DISTINCT CONCAT(order_id, '-', CAST(order_item_id AS STRING))) AS distinct_natural_keys
FROM `olist-analytics-500708.olist_serving.fact_order_item_fulfillment`;
-- Expected: all three equal

-- V3. Referential integrity -- every foreign key must resolve (no
-- unexpected NULLs from a failed join, despite the defensive LEFT JOINs)
SELECT
  COUNTIF(customer_key IS NULL)      AS unresolved_customer,
  COUNTIF(seller_key IS NULL)        AS unresolved_seller,
  COUNTIF(product_key IS NULL)       AS unresolved_product,
  COUNTIF(order_date_key IS NULL)    AS unresolved_date,
  COUNTIF(data_quality_key IS NULL)  AS unresolved_data_quality
FROM `olist-analytics-500708.olist_serving.fact_order_item_fulfillment`;
-- Expected: all 0. Any non-zero value here is a genuine implementation
-- defect (a join that should have matched, per prior RI confirmation,
-- did not) -- investigate immediately, do not silently accept.

-- V4. is_delivered_on_time NULL-handling -- the single highest-stakes
-- check in this entire fact table, per the earlier validation finding.
-- Confirm null count matches the known null_customer_date baseline,
-- and confirm NO row has is_delivered_on_time = FALSE where the
-- underlying delivery date is actually NULL (would indicate an
-- accidental COALESCE-to-FALSE bug).
SELECT
  COUNTIF(is_delivered_on_time IS NULL) AS null_on_time_flag,
  COUNTIF(is_delivered_on_time = FALSE
          AND order_id IN (
            SELECT order_id FROM `olist-analytics-500708.olist_clean.orders`
            WHERE order_delivered_customer_date IS NULL
          )) AS false_positive_bug_check
FROM `olist-analytics-500708.olist_serving.fact_order_item_fulfillment`;
-- Expected: false_positive_bug_check MUST be 0. null_on_time_flag
-- should be > 0 and roughly proportional to the known 2,965-row
-- null_delivered_customer_date population from Silver (proportional,
-- not exactly equal, since this is item-grain and orders have
-- varying item counts).

-- V5. Freight ratio safety -- confirm SAFE_DIVIDE behaved correctly,
-- no errors, and NULL only where price = 0 (currently should be none)
SELECT
  COUNTIF(price = 0 AND freight_to_price_ratio IS NOT NULL) AS unexpected_non_null,
  COUNTIF(price != 0 AND freight_to_price_ratio IS NULL) AS unexpected_null
FROM `olist-analytics-500708.olist_serving.fact_order_item_fulfillment`;
-- Expected: both 0

-- V6. Multi-review resolution check -- confirm review_score reflects
-- the MOST RECENT review for a known multi-review order (spot check)
SELECT
  f.order_id, f.review_score AS fact_review_score,
  r.review_score AS raw_review_score, r.review_creation_date
FROM `olist-analytics-500708.olist_serving.fact_order_item_fulfillment` f
JOIN `olist-analytics-500708.olist_clean.order_reviews` r
  ON f.order_id = r.order_id
WHERE f.order_id IN (
  SELECT order_id FROM `olist-analytics-500708.olist_clean.order_reviews`
  GROUP BY order_id HAVING COUNT(*) > 1
)
ORDER BY f.order_id, r.review_creation_date DESC
LIMIT 20;
-- Manually confirm: fact_review_score matches the row with the LATEST
-- review_creation_date for each order_id.

-- V7. has_fulfillment_anomaly consistency -- must be TRUE whenever ANY
-- of the underlying seven flags is TRUE, and only then
SELECT COUNT(*) AS inconsistent_rows
FROM `olist-analytics-500708.olist_serving.fact_order_item_fulfillment` f
JOIN `olist-analytics-500708.olist_serving.data_quality_flags` dqf
  ON f.data_quality_key = dqf.data_quality_key
WHERE f.has_fulfillment_anomaly != (
  dqf.is_delivery_before_carrier_anomaly
  OR dqf.is_delivered_missing_approval_anomaly
  OR dqf.is_delivered_missing_multiple_dates_anomaly
  OR dqf.is_carrier_before_approval_anomaly
  OR dqf.is_canceled_with_delivery_date_anomaly
  OR dqf.is_shipping_anomaly
);
-- Expected: 0

-- V8. No payment data present -- explicit confirmation of scope
-- exclusion, not just an absent column check
SELECT column_name
FROM `olist-analytics-500708.olist_serving`.INFORMATION_SCHEMA.COLUMNS
WHERE table_name = 'fact_order_item_fulfillment'
  AND LOWER(column_name) LIKE '%payment%';
-- Expected: 0 rows returned

-- REFERENTIAL INTEGRITY CHECKS -
-- RI-check 1: every customer_key in the fact table exists in dim_customer
SELECT COUNT(*) AS orphan_customer_refs
FROM `olist-analytics-500708.olist_serving.fact_order_item_fulfillment` f
LEFT JOIN `olist-analytics-500708.olist_serving.dim_customer` dc
  ON f.customer_key = dc.customer_key
WHERE dc.customer_key IS NULL AND f.customer_key IS NOT NULL;

-- RI-check 2: every seller_key exists in dim_seller
SELECT COUNT(*) AS orphan_seller_refs
FROM `olist-analytics-500708.olist_serving.fact_order_item_fulfillment` f
LEFT JOIN `olist-analytics-500708.olist_serving.dim_seller` ds
  ON f.seller_key = ds.seller_key
WHERE ds.seller_key IS NULL AND f.seller_key IS NOT NULL;

-- RI-check 3: every product_key exists in dim_product
SELECT COUNT(*) AS orphan_product_refs
FROM `olist-analytics-500708.olist_serving.fact_order_item_fulfillment` f
LEFT JOIN `olist-analytics-500708.olist_serving.dim_product` dp
  ON f.product_key = dp.product_key
WHERE dp.product_key IS NULL AND f.product_key IS NOT NULL;

-- RI-check 4: every order_date_key exists in dim_date
SELECT COUNT(*) AS orphan_date_refs
FROM `olist-analytics-500708.olist_serving.fact_order_item_fulfillment` f
LEFT JOIN `olist-analytics-500708.olist_serving.dim_date` dd
  ON f.order_date_key = dd.date_key
WHERE dd.date_key IS NULL AND f.order_date_key IS NOT NULL;

-- RI-check 5: every data_quality_key exists in data_quality_flags
SELECT COUNT(*) AS orphan_dq_refs
FROM `olist-analytics-500708.olist_serving.fact_order_item_fulfillment` f
LEFT JOIN `olist-analytics-500708.olist_serving.data_quality_flags` dqf
  ON f.data_quality_key = dqf.data_quality_key
WHERE dqf.data_quality_key IS NULL AND f.data_quality_key IS NOT NULL;

-- All five expected: 0

SELECT customer_unique_id, COUNT(*) AS n
FROM `olist-analytics-500708.olist_serving.dim_customer`
GROUP BY customer_unique_id
HAVING COUNT(*) > 1;

WITH customer_first_orders AS (
  SELECT
    c.customer_unique_id,
    o.order_id,
    ROW_NUMBER() OVER (
      PARTITION BY c.customer_unique_id
      ORDER BY o.order_purchase_timestamp ASC
    ) AS rk
  FROM `olist-analytics-500708.olist_clean.customers` c
  JOIN `olist-analytics-500708.olist_clean.orders` o
    ON c.customer_id = o.customer_id
),

first_orders_only AS (
  SELECT customer_unique_id, order_id
  FROM customer_first_orders
  WHERE rk = 1
),

first_orders_with_no_items AS (
  SELECT fo.customer_unique_id
  FROM first_orders_only fo
  LEFT JOIN `olist-analytics-500708.olist_clean.order_items` oi
    ON fo.order_id = oi.order_id
  WHERE oi.order_id IS NULL
)

SELECT
  (SELECT COUNT(*) FROM first_orders_with_no_items) AS expected_null_count,
  (SELECT COUNT(*) FROM `olist-analytics-500708.olist_serving.dim_customer`
   WHERE first_purchase_category IS NULL) AS actual_null_count;


SELECT
  category_name,
  COUNT(*) AS product_count
FROM `olist-analytics-500708.olist_serving.dim_product`
WHERE category_name_english = category_name  -- fallback fired
  AND category_name != 'unknown'              -- exclude the expected placeholder case
GROUP BY category_name
ORDER BY product_count DESC;

-- Confirms whether is_delivered_on_time NULL count at item grain is
-- AT LEAST the order-grain baseline (2,965), accounting for item fan-out.
-- If item-grain NULLs < order-grain NULLs, something is dropping or
-- miscounting NULL rows -- worth investigating before sign-off.

SELECT
  (SELECT COUNT(*) FROM `olist-analytics-500708.olist_clean.orders`
   WHERE order_delivered_customer_date IS NULL) AS order_grain_null_baseline,

  (SELECT COUNT(*) FROM `olist-analytics-500708.olist_serving.fact_order_item_fulfillment`
   WHERE is_delivered_on_time IS NULL) AS item_grain_null_actual,

  -- Direct join-based cross-check: for every order with a NULL
  -- delivery date, count its item rows in the fact table and compare
  -- against how many of those rows actually show NULL is_delivered_on_time.
  (SELECT COUNT(*)
   FROM `olist-analytics-500708.olist_serving.fact_order_item_fulfillment` f
   JOIN `olist-analytics-500708.olist_clean.orders` o
     ON f.order_id = o.order_id
   WHERE o.order_delivered_customer_date IS NULL
     AND f.is_delivered_on_time IS NOT NULL  -- this should NEVER happen
  ) AS mismatched_rows;
-- mismatched_rows MUST be 0. If item_grain_null_actual < order_grain_null_baseline,
-- but mismatched_rows = 0, the gap is explained by RI-7 orders (no line
-- items at all -- those orders contribute ZERO rows to this fact table,
-- so their NULL delivery dates never appear here, which is expected
-- and correct, not a bug).

-- Isolate the 3-row gap: customers whose first order HAS items, but
-- whose category still resolved to NULL -- i.e. items exist but
-- product_id didn't match products.
WITH customer_first_orders AS (
  SELECT
    c.customer_unique_id,
    o.order_id,
    ROW_NUMBER() OVER (
      PARTITION BY c.customer_unique_id
      ORDER BY o.order_purchase_timestamp ASC
    ) AS rk
  FROM `olist-analytics-500708.olist_clean.customers` c
  JOIN `olist-analytics-500708.olist_clean.orders` o
    ON c.customer_id = o.customer_id
),
first_orders_only AS (
  SELECT customer_unique_id, order_id FROM customer_first_orders WHERE rk = 1
),
first_orders_with_items_but_no_category AS (
  SELECT fo.customer_unique_id, fo.order_id, oi.product_id
  FROM first_orders_only fo
  JOIN `olist-analytics-500708.olist_clean.order_items` oi
    ON fo.order_id = oi.order_id  -- INNER: confirms items DO exist
  LEFT JOIN `olist-analytics-500708.olist_clean.products` p
    ON oi.product_id = p.product_id
  WHERE p.product_id IS NULL  -- but product lookup failed
)
SELECT * FROM first_orders_with_items_but_no_category;
-- If this returns exactly 3 rows, that fully explains the gap and it's
-- benign (correct NULL, different cause than documented). If it
-- returns 0, the gap has a different, unexplained source and needs
-- further investigation before accepting 706 as correct.

SELECT
  p.product_category_name AS products_side,
  LENGTH(p.product_category_name) AS products_side_length,
  ct.category_name_portuguese AS translation_side,
  LENGTH(ct.category_name_portuguese) AS translation_side_length
FROM `olist-analytics-500708.olist_clean.products` p
FULL OUTER JOIN `olist-analytics-500708.olist_clean.category_translation` ct
  ON p.product_category_name = ct.category_name_portuguese
WHERE p.product_category_name = 'cool_stuff'
   OR ct.category_name_portuguese LIKE '%cool%stuff%';
