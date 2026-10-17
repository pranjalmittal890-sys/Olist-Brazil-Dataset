-- =====================================================================
-- ANALYTICAL DATASET: order_experience_features
-- Objective 3: Customer Experience & Satisfaction
--
-- Purpose: one trusted row per ORDER carrying the review outcome and the
--          fulfillment-quality signals that might explain it, so we can
--          honestly TEST whether operational failures (data anomalies and
--          late delivery) actually drive satisfaction down -- rather than
--          assume they do. Built once so the Python/statistics phase and
--          the CX dashboard read the same numbers.
--
-- Source: serving LAYER ONLY --
--          serving.fact_order_item_fulfillment (review_score,
--          has_fulfillment_anomaly, is_delivered_on_time,
--          delivery_estimate_error_days, keys),
--          serving.data_quality_flags (to build the anomaly severity tier),
--          serving.dim_customer (region).
--
-- Grain: one row per order_id.
-- =====================================================================

CREATE OR REPLACE TABLE `olist-analytics-500708.olist_analytics.order_experience_features` AS

WITH fact_with_flags AS (
  SELECT
  f.order_id,
    f.order_status,
    f.customer_key,
    f.seller_key,
    f.product_key,
    f.order_date_key,
    f.price,
    f.freight_value,
    f.is_delivered_on_time,
    f.delivery_estimate_error_days,
    f.review_score,
    f.has_review,
  f.has_fulfillment_anomaly,
    dqf.is_delivered_missing_approval_anomaly,
    dqf.is_delivered_missing_multiple_dates_anomaly,
    dqf.is_carrier_before_approval_anomaly,
    dqf.is_delivery_before_carrier_anomaly,
    dqf.is_canceled_with_delivery_date_anomaly,
    dqf.is_delivered_missing_final_date_only,
    dqf.is_delivered_missing_carrier_anomaly,
    dqf.is_shipping_anomaly
FROM `olist-analytics-500708.olist_serving.fact_order_item_fulfillment` f
  LEFT JOIN `olist-analytics-500708.olist_serving.data_quality_flags` dqf
    ON f.data_quality_key = dqf.data_quality_key
),

order_level AS (
  -- Collapse item rows to one row per order.
  -- Revenue summed at item level. Review and delivery signals are
  -- order-level (ANY_VALUE safe). Anomaly flags ORed across items
  -- so "did ANY item of this order have this problem" is answered correctly.
SELECT
  order_id,
  ANY_VALUE(order_status)                 AS order_status,
    ANY_VALUE(customer_key)                 AS customer_key,
    ANY_VALUE(seller_key)                       AS seller_key,
    ANY_VALUE(order_date_key)               AS order_purchase_date_key,
    ANY_VALUE(review_score)                 AS review_score,
    ANY_VALUE(has_review)                       AS has_review,
    ANY_VALUE(is_delivered_on_time)         AS is_delivered_on_time,
    ANY_VALUE(delivery_estimate_error_days) AS delivery_estimate_error_days,
  LOGICAL_OR(has_fulfillment_anomaly)   AS has_fulfillment_anomaly,
  ROUND(SUM(price), 2)                        AS order_total_revenue,

  -- Individual flags ORed to order grain -- used only to derive the
    -- severity tier in the next step.
    LOGICAL_OR(is_canceled_with_delivery_date_anomaly)      AS f_canceled_with_delivery,
    LOGICAL_OR(is_delivered_missing_approval_anomaly)       AS f_missing_approval,
    LOGICAL_OR(is_delivered_missing_multiple_dates_anomaly) AS f_missing_multiple,
    LOGICAL_OR(is_carrier_before_approval_anomaly)          AS f_carrier_before_approval,
    LOGICAL_OR(is_delivery_before_carrier_anomaly)          AS f_delivery_before_carrier,
    LOGICAL_OR(is_delivered_missing_final_date_only)       AS f_missing_final_date,
    logical_or(is_delivered_missing_carrier_anomaly)        AS f_missing_carrier,
    LOGICAL_OR(is_shipping_anomaly)                         AS f_shipping
  FROM fact_with_flags
  GROUP BY order_id
),
-- Primary product: highest-priced item in the order.
-- Same deterministic logic used in order_delivery_features and
-- seller_features — consistent across all four analytical tables.
ranked_items AS (
  SELECT
    order_id,
    seller_key,
    product_key,
    price,
    ROW_NUMBER() OVER (
      PARTITION BY order_id
      ORDER BY price DESC, seller_key ASC
    ) AS price_rank
  FROM fact_with_flags
),

primary_item AS (
  SELECT
    order_id,
    seller_key  AS primary_seller_key,
    product_key AS primary_product_key
  FROM ranked_items
  WHERE price_rank = 1
),

order_features AS (
SELECT
    ol.order_id,
    ol.order_status,

  -- Customer geography - customer_state: supporting dimension for "which regions have worst satisfaction"
    ol.customer_key,
    dc.customer_state,

 -- is_cross_state: explanatory variable
  -- Why here: tests whether cross-state orders generate more dissatisfaction
  -- than same-state orders. If yes and it disappears after controlling for lateness, the fix is delivery speed. If it persists, something structural about cross-state fulfillment affects perception beyond just timing.
  (dc.customer_state != ds.seller_state)        AS is_cross_state,

    ol.order_purchase_date_key,

   -- review_score: what the customer said — the number being explained
  ol.review_score,
  -- has_review: supporting dimension Critical for analysis validity: all satisfaction analysis is conditional
  -- on this population. If dissatisfied customers review more or less than satisfied ones, the numbers are biased. Test this before interpreting anything.
  ol.has_review,

    -- Detractor flag: a genuinely bad review (1-2 stars). NULL when there is no review -- never treated as FALSE, because "no review" is not the same as "not a bad review".
    CASE
    WHEN ol.review_score IS NULL THEN NULL
      ELSE ol.review_score <= 2
    END AS is_negative_review,

     -- ---- Fulfillment-quality drivers (the candidate "X"s) ----
    ol.has_fulfillment_anomaly,

  -- anomaly_severity_tier: granular explanatory variable. Tests whether the TYPE and SEVERITY of anomaly matters, not just presence. HYPOTHESIS (not a proven ranking) — the tier ordering will be tested in Python. 'none' = no anomaly, consistent with has_fulfillment_anomaly.
    CASE
      WHEN ol.f_canceled_with_delivery THEN 'contradiction'
      WHEN ol.f_missing_approval 
        OR ol.f_missing_multiple
        OR ol.f_missing_final_date
        OR ol.f_missing_carrier THEN 'missing_data'
      WHEN ol.f_carrier_before_approval
           OR ol.f_delivery_before_carrier
           OR ol.f_shipping THEN 'timing_or_value'
      ELSE 'none'
    END AS anomaly_severity_tier,

     -- The customer-VISIBLE driver: was it on time, and by how much.
    ol.is_delivered_on_time,
    ol.delivery_estimate_error_days,

-- Readable lateness groups (BQ3), based on the day-count miss so it
    -- reads the way a customer experiences it. 'not_delivered' when the
    -- order never reached the customer (error is NULL) -- these are kept
    -- separate, never mixed into a late/early bucket.
    CASE
      WHEN ol.delivery_estimate_error_days IS NULL THEN 'not delivered'
      WHEN OL.delivery_estimate_error_days < 0 THEN 'early'
      WHEN ol.delivery_estimate_error_days =  0 THEN 'on_time'
      WHEN ol.delivery_estimate_error_days <= 3 THEN 'slightly_late'
      ELSE 'very_late'
    END AS lateness_bucket,
   ol.order_total_revenue,
    dp.category_name_english    AS primary_category
FROM order_level ol
  LEFT JOIN primary_item pi
  ON ol.order_id = pi.order_id
LEFT JOIN `olist-analytics-500708.olist_serving.dim_customer` dc
  ON ol.customer_key = dc.customer_key
LEFT JOIN `olist-analytics-500708.olist_serving.dim_seller` ds
  ON pi.primary_seller_key = ds.seller_key
LEFT JOIN `olist-analytics-500708.olist_serving.dim_product` dp
  ON pi.primary_product_key = dp.product_key
)

SELECT * FROM order_features;

-- ---------------------------------------------------------------------
-- V1. Row count reconciliation -- one row per order that has items.
-- ---------------------------------------------------------------------
SELECT
  (SELECT COUNT(DISTINCT order_id) FROM `olist-analytics-500708.olist_serving.fact_order_item_fulfillment`) AS fact_distinct_orders,
  (SELECT COUNT(*) FROM `olist-analytics-500708.olist_analytics.order_experience_features`) AS feature_rows;
-- Expected: equal (~98,666 -- the 775 no-item orders are excluded by construction)

-- ---------------------------------------------------------------------
-- V2. Grain + duplicate check -- exactly one row per order
-- ---------------------------------------------------------------------
SELECT COUNT(*) AS total_rows, COUNT(DISTINCT order_id) AS distinct_orders
FROM `olist-analytics-500708.olist_analytics.order_experience_features`;
-- Expected: equal

SELECT order_id, COUNT(*) AS n
FROM `olist-analytics-500708.olist_analytics.order_experience_features`
GROUP BY order_id HAVING COUNT(*) > 1;
-- Expected: 0 rows

-- ---------------------------------------------------------------------
-- V3. Null validation -- columns that must never be null
-- ---------------------------------------------------------------------
SELECT
  COUNTIF(order_id IS NULL)              AS null_order_id,
  COUNTIF(order_status IS NULL)          AS null_status,
  COUNTIF(customer_state IS NULL)        AS null_customer_state,
  COUNTIF(anomaly_severity_tier IS NULL) AS null_tier,
  COUNTIF(lateness_bucket IS NULL)       AS null_bucket,
  COUNTIF(has_review IS NULL)            AS null_has_review,
  COUNTIF(has_fulfillment_anomaly IS NULL) AS null_anomaly_flag
FROM `olist-analytics-500708.olist_analytics.order_experience_features`;
-- Expected: all 0 (review_score / is_delivered_on_time / error_days MAY be null)

-- ---------------------------------------------------------------------
-- V4. Review-outcome business logic
-- ---------------------------------------------------------------------
SELECT
  COUNTIF(has_review != (review_score IS NOT NULL))                              AS review_flag_mismatch,   -- 0
  COUNTIF(review_score IS NOT NULL AND review_score NOT BETWEEN 1 AND 5)          AS bad_score,              -- 0
  COUNTIF(review_score IS NULL AND is_negative_review IS NOT NULL)                AS neg_flag_when_no_review,-- 0
  COUNTIF(review_score IS NOT NULL AND is_negative_review != (review_score <= 2)) AS neg_flag_logic_error    -- 0
FROM `olist-analytics-500708.olist_analytics.order_experience_features`;

-- ---------------------------------------------------------------------
-- V5. Review null rate reconciles with the fact at order grain
-- ---------------------------------------------------------------------
SELECT
  (SELECT COUNT(DISTINCT order_id) FROM `olist-analytics-500708.olist_serving.fact_order_item_fulfillment`
   WHERE review_score IS NOT NULL) AS fact_reviewed_orders,
  (SELECT COUNTIF(has_review) FROM `olist-analytics-500708.olist_analytics.order_experience_features`) AS feature_reviewed_orders;
-- Expected: equal

-- ---------------------------------------------------------------------
-- V6. Severity tier logic -- 'none' iff no anomaly; tiers cover all rows
-- ---------------------------------------------------------------------
SELECT
  COUNTIF((anomaly_severity_tier = 'none') != (has_fulfillment_anomaly = FALSE)) AS tier_vs_flag_mismatch, -- 0
  COUNTIF(anomaly_severity_tier NOT IN ('none','timing_or_value','missing_data','contradiction')) AS bad_tier_value -- 0
FROM `olist-analytics-500708.olist_analytics.order_experience_features`;

-- ---------------------------------------------------------------------
-- V7. Lateness bucket logic -- not_delivered maps to NULLs; sign correct
-- ---------------------------------------------------------------------
SELECT
  COUNTIF((lateness_bucket = 'not delivered') != (delivery_estimate_error_days IS NULL)) AS notdelivered_vs_error_mismatch, -- 0
  COUNTIF((lateness_bucket = 'not delivered') != (is_delivered_on_time IS NULL))         AS notdelivered_vs_ontime_mismatch, -- 0
  COUNTIF(lateness_bucket = 'early'     AND delivery_estimate_error_days >= 0)  AS early_logic_error,     -- 0
  COUNTIF(lateness_bucket = 'on_time'   AND delivery_estimate_error_days != 0)  AS ontime_logic_error,    -- 0
  COUNTIF(lateness_bucket = 'very_late' AND delivery_estimate_error_days <= 3)  AS verylate_logic_error   -- 0
FROM `olist-analytics-500708.olist_analytics.order_experience_features`;

-- ---------------------------------------------------------------------
-- V8. has_fulfillment_anomaly reconciles with the fact (order-level OR)
-- ---------------------------------------------------------------------
SELECT
  (SELECT COUNT(DISTINCT order_id) FROM `olist-analytics-500708.olist_serving.fact_order_item_fulfillment`
   WHERE has_fulfillment_anomaly) AS fact_anomaly_orders,
  (SELECT COUNTIF(has_fulfillment_anomaly) FROM `olist-analytics-500708.olist_analytics.order_experience_features`) AS feature_anomaly_orders;
-- Expected: equal

-- ---------------------------------------------------------------------
-- V9. Distribution sanity
-- ---------------------------------------------------------------------
SELECT review_score, COUNT(*) AS n
FROM `olist-analytics-500708.olist_analytics.order_experience_features`
WHERE review_score IS NOT NULL
GROUP BY review_score ORDER BY review_score;
-- Expected: heavily skewed toward 5 (known Olist pattern)

SELECT lateness_bucket, COUNT(*) AS n
FROM `olist-analytics-500708.olist_analytics.order_experience_features`
GROUP BY lateness_bucket ORDER BY n DESC;
-- Expected: 'early' dominant (padded estimates), 'very_late' a small tail

SELECT anomaly_severity_tier, COUNT(*) AS n
FROM `olist-analytics-500708.olist_analytics.order_experience_features`
GROUP BY anomaly_severity_tier ORDER BY n DESC;
-- Expected: 'none' dominant

-- ---------------------------------------------------------------------
-- V10. Denominator preview (a sanity look, NOT the real test) --
-- confirms the ingredients behave before the Python/stats phase.
-- ---------------------------------------------------------------------
SELECT
  has_fulfillment_anomaly,
  COUNT(*)                                   AS orders,
  ROUND(COUNTIF(has_review) / COUNT(*), 4)   AS review_rate,           -- BQ5 preview
  ROUND(AVG(IF(has_review, review_score, NULL)), 3) AS avg_review_score -- BQ1 preview (reviewed only)
FROM `olist-analytics-500708.olist_analytics.order_experience_features`
GROUP BY has_fulfillment_anomaly;

SELECT
  lateness_bucket,
  COUNT(*) AS orders,
  ROUND(AVG(IF(has_review, review_score, NULL)), 3) AS avg_review_score -- BQ3 preview
FROM `olist-analytics-500708.olist_analytics.order_experience_features`
WHERE lateness_bucket != 'not_delivered'
GROUP BY lateness_bucket ORDER BY avg_review_score;
-- Watch: 'very_late' should show the lowest average if lateness hurts sentiment.

-- ---------------------------------------------------------------------
-- V11. Business spot check -- very late AND badly reviewed orders
-- ---------------------------------------------------------------------
SELECT order_id, customer_state, delivery_estimate_error_days, review_score, anomaly_severity_tier
FROM `olist-analytics-500708.olist_analytics.order_experience_features`
WHERE lateness_bucket = 'very_late' AND is_negative_review
ORDER BY delivery_estimate_error_days DESC
LIMIT 20;
-- Eyeball: these should read as coherent "arrived very late, got 1-2 stars" cases.

SELECT
  anomaly_severity_tier,
  COUNT(*) AS order_count
FROM `olist-analytics-500708.olist_analytics.order_experience_features`
GROUP BY anomaly_severity_tier
ORDER BY order_count DESC;

-- Cross-check: has_fulfillment_anomaly vs severity tier consistency
SELECT COUNT(*) AS inconsistency
FROM `olist-analytics-500708.olist_analytics.order_experience_features`
WHERE has_fulfillment_anomaly = TRUE AND anomaly_severity_tier = 'none';
