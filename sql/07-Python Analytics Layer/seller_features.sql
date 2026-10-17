-- =====================================================================
-- ANALYTICAL DATASET: seller_features
-- Purpose: seller-grain rollup answering the Seller Performance &
--          Operational Risk business objective. Built once here so
--          Python analysis, statistics, and dashboards all read from
--          the same trusted numbers instead of re-deriving them.
-- Source: serving.fact_order_item_fulfillment, serving.dim_seller,
--          serving.data_quality_flags
-- Grain: one row per seller_id.
-- Note: has_sufficient_sample_size and has_sufficient_delivery_sample_size
--       use PLACEHOLDER thresholds (20 orders). These will be replaced
--       with statistically-determined values in the Python/Statistics
--       phase of this project -- not treated as final here.
-- =====================================================================

CREATE OR REPLACE TABLE `olist-analytics-500708.olist_analytics.seller_features` AS

-- ============================================================
-- Step 1: Join fact to flags and product info in one pass
-- ============================================================
WITH fact_with_flags AS (
  select 
  f.seller_key,f.order_id, 
  f.price, f.freight_value,
f.is_delivered_on_time,
f.has_review,
f.review_score,
-- f.has_fulfillment_anomaly,
dp.category_name,
dqf.is_delivery_before_carrier_anomaly, 
dqf.is_delivered_missing_approval_anomaly, 
dqf.is_delivered_missing_multiple_dates_anomaly,
dqf.is_carrier_before_approval_anomaly,
dqf.is_canceled_with_delivery_date_anomaly,
dqf.is_delivered_missing_final_date_only,
dqf.is_delivered_missing_carrier_anomaly,
dqf.is_shipping_anomaly
from `olist-analytics-500708.olist_serving.fact_order_item_fulfillment` f
LEFT JOIN `olist-analytics-500708.olist_serving.dim_product` dp
ON f.product_key = dp.product_key
left join `olist-analytics-500708.olist_serving.data_quality_flags` dqf
using(data_quality_key)
),
-- ============================================================
-- Step 2: Volume — item and order counts
-- ============================================================
seller_volume AS (
select seller_key, 
COUNT(DISTINCT order_id) AS total_orders,
COUNT(*)                 AS total_items
from fact_with_flags
group by seller_key
),
-- ============================================================
-- Step 3: Revenue and freight
-- Both are item-level facts, so SUM is correct at item grain.
-- avg_freight_to_price uses SAFE_DIVIDE per item, then averaged —
-- not total_freight/total_price, which would be weighted by order
-- size and harder to interpret at seller level.
-- ============================================================
seller_revenue AS (
  SELECT
    seller_key,
    ROUND(SUM(price), 2)                                       AS total_revenue,
    ROUND(SUM(freight_value), 2)                               AS total_freight,
    ROUND(AVG(SAFE_DIVIDE(freight_value, price)), 4)           AS avg_freight_to_price_ratio,
    ROUND(SAFE_DIVIDE(SUM(price), COUNT(DISTINCT order_id)), 2) AS avg_order_value
  FROM fact_with_flags
  GROUP BY seller_key
),
-- ============================================================
-- Step 4: Primary category per seller
-- Defined as the category generating the most revenue for that seller. Revenue-based is more meaningful than count-based
-- because a seller who sells 90% cheap items + 10% expensive ones is commercially a seller in the expensive category.
-- NULL category rows are excluded — they represent products with no category in the products table, not a seller-level issue.
-- ============================================================
seller_category_revenue AS (
  SELECT
    seller_key,
    category_name,
    SUM(price) AS category_revenue
  FROM fact_with_flags
  WHERE category_name IS NOT NULL
  GROUP BY seller_key, category_name
),

seller_primary_category AS (
  SELECT
    seller_key,
    category_name AS primary_category
  FROM (
    SELECT
      seller_key,
      category_name,
      ROW_NUMBER() OVER (
        PARTITION BY seller_key
        ORDER BY category_revenue DESC, category_name ASC
      ) AS cat_rank
    FROM seller_category_revenue
  )
  WHERE cat_rank = 1
),

-- ============================================================
-- Step 5: Distinct categories sold per seller
-- Tells you if a seller is a specialist or a generalist.
-- ============================================================
seller_category_count AS (
  SELECT
    seller_key,
    COUNT(DISTINCT category_name) AS distinct_categories_sold
  FROM fact_with_flags
  WHERE category_name IS NOT NULL
  GROUP BY seller_key
),

-- ============================================================
-- Step 6: Review score — order-deduplicated before averaging. The fact table is item-grain. A 3-item order has one review,
-- not three. Average at order level first, then at seller level.Only orders with a review are included (has_review = TRUE).
-- ============================================================
order_review_deduped AS (
  SELECT DISTINCT
    seller_key,
    order_id,
    review_score
  FROM fact_with_flags
  WHERE has_review = TRUE
    AND review_score IS NOT NULL
),

seller_reviews AS (
  SELECT
    seller_key,
    COUNT(DISTINCT order_id)                AS review_count,
    ROUND(AVG(review_score), 3)             AS avg_review_score,
    ROUND(COUNTIF(review_score <= 2) / COUNT(*), 4) AS pct_negative_reviews
  FROM order_review_deduped
  GROUP BY seller_key
),
-- ============================================================
-- Step 7: Item-native anomaly — shipping only Counted at item grain because it originates from
-- order_items.shipping_limit_date, not order timestamps.
-- ============================================================
seller_item_anomalies AS (
  SELECT
    seller_key,
    COUNTIF(is_shipping_anomaly)     AS shipping_anomaly_count
  FROM fact_with_flags
  GROUP BY seller_key
),
-- ============================================================
-- Step 8: Order-level anomalies — collapsed to order grain. 7 flags originate from order timestamps. Counting them
-- at item grain would overcount on multi-item orders.One row per (seller, order) before counting.
-- ============================================================
order_level_anomalies AS (
  SELECT DISTINCT
    seller_key,
    order_id,
    is_delivered_missing_approval_anomaly,
    is_delivered_missing_multiple_dates_anomaly,
    is_carrier_before_approval_anomaly,
    is_delivery_before_carrier_anomaly,
    is_canceled_with_delivery_date_anomaly,
    is_delivered_missing_final_date_only,
    is_delivered_missing_carrier_anomaly,
    
    (
      is_delivered_missing_approval_anomaly
      OR is_delivered_missing_multiple_dates_anomaly
      OR is_carrier_before_approval_anomaly
      OR is_delivery_before_carrier_anomaly
      OR is_canceled_with_delivery_date_anomaly
      OR is_delivered_missing_final_date_only
      OR is_delivered_missing_carrier_anomaly
    ) AS order_has_any_order_level_anomaly
  FROM fact_with_flags
),

seller_order_anomalies AS (
  SELECT
    seller_key,
    COUNTIF(is_delivered_missing_approval_anomaly)         AS delivered_missing_approval_orders,
    COUNTIF(is_delivered_missing_multiple_dates_anomaly)   AS delivered_missing_multiple_dates_orders,
    COUNTIF(is_carrier_before_approval_anomaly)            AS carrier_before_approval_orders,
    COUNTIF(is_delivery_before_carrier_anomaly)            AS delivery_before_carrier_orders,
    COUNTIF(is_canceled_with_delivery_date_anomaly)        AS canceled_with_delivery_date_orders,
    COUNTIF(order_has_any_order_level_anomaly)             AS order_level_anomalous_order_count,
    COUNTIF(is_delivered_missing_final_date_only)          AS delivered_missing_final_date_orders,
    COUNTIF(is_delivered_missing_carrier_anomaly)          AS delivered_missing_carrier_anomaly_orders
  FROM order_level_anomalies
  GROUP BY seller_key
),
-- ============================================================
-- Step 9: Delivery — order-deduplicated before counting is_delivered_on_time is an order fact, not an item fact.
-- Same logic as anomalies: collapse first, then count. Denominator = orders with a known outcome (not NULL).
-- Never-delivered orders are excluded, not counted as late.
-- ============================================================
order_level_delivery AS (
  SELECT DISTINCT
    seller_key,
    order_id,
    is_delivered_on_time
  FROM fact_with_flags
),
seller_delivery AS (
  SELECT
    seller_key,
    COUNT(DISTINCT IF(is_delivered_on_time IS NOT NULL, order_id, NULL)) AS delivered_order_count,
    COUNTIF(is_delivered_on_time = FALSE) AS late_delivery_count
  FROM order_level_delivery
  GROUP BY seller_key
),

seller_features_combined AS (
  select
  ds.seller_key,
  ds.seller_id,
  ds.seller_city,
  ds.seller_state,
  ds.seller_tenure_bucket,
  ds.seller_volume_tier,

  COALESCE(sv.total_orders, 0) AS total_orders,
  COALESCE(sv.total_items, 0)  AS total_items,

  -- Revenue and cost structure
    COALESCE(sr.total_revenue, 0)                 AS total_revenue,
    COALESCE(sr.total_freight, 0)                 AS total_freight,
    COALESCE(sr.avg_order_value, 0)               AS avg_order_value,
    sr.avg_freight_to_price_ratio,

    -- Product focus
    spc.primary_category,
    COALESCE(scc.distinct_categories_sold, 0)     AS distinct_categories_sold,

    -- Customer satisfaction
    COALESCE(srev.review_count, 0)                AS review_count,
    srev.avg_review_score,
    srev.pct_negative_reviews,

    -- Delivery reliability (order-grain, NULL = unknown outcome excluded)
    COALESCE(sd.delivered_order_count, 0)         AS delivered_order_count,
    COALESCE(sd.late_delivery_count, 0)           AS late_delivery_count,
    SAFE_DIVIDE(COALESCE(sd.late_delivery_count, 0), NULLIF(sd.delivered_order_count, 0))   AS late_delivery_rate,

    -- ITEM-LEVEL SUMMARY (fully attributable, no sharing ambiguity)
    COALESCE(sia.shipping_anomaly_count, 0) AS shipping_anomaly_count,
    SAFE_DIVIDE(COALESCE(sia.shipping_anomaly_count, 0), NULLIF(sv.total_items, 0)) AS item_level_anomaly_rate,

    -- ORDER-LEVEL SUMMARY (shared across co-sellers on multi-seller orders)
    COALESCE(soa.order_level_anomalous_order_count, 0) AS order_level_anomalous_order_count,
    SAFE_DIVIDE(COALESCE(soa.order_level_anomalous_order_count, 0),NULLIF(sv.total_orders, 0)) AS order_level_anomaly_rate,

    -- Order-level flags: now counted per ORDER, not per item.
    COALESCE(soa.delivered_missing_approval_orders, 0) AS delivered_missing_approval_orders,
    COALESCE(soa.delivered_missing_multiple_dates_orders, 0) AS delivered_missing_multiple_dates_orders,
    COALESCE(soa.carrier_before_approval_orders, 0) AS carrier_before_approval_orders,
    COALESCE(soa.delivery_before_carrier_orders, 0) AS delivery_before_carrier_orders,
    COALESCE(soa.canceled_with_delivery_date_orders, 0) AS canceled_with_delivery_date_orders,
    COALESCE(soa.delivered_missing_final_date_orders, 0) AS delivered_missing_final_date_orders,
    COALESCE(soa.delivered_missing_carrier_anomaly_orders, 0) AS delivered_missing_carrier_anomaly_orders,
  
-- SAMPLE SIZE GATES (placeholder thresholds, unchanged)
    (COALESCE(sv.total_orders, 0) >= 20) AS has_sufficient_sample_size,
    (COALESCE(sd.delivered_order_count, 0) >= 20) AS has_sufficient_delivery_sample_size

  FROM `olist-analytics-500708.olist_serving.dim_seller` ds
  LEFT JOIN seller_volume sv           ON ds.seller_key = sv.seller_key
  LEFT JOIN seller_revenue sr         ON ds.seller_key = sr.seller_key
  LEFT JOIN seller_primary_category spc ON ds.seller_key = spc.seller_key
  LEFT JOIN seller_category_count scc ON ds.seller_key = scc.seller_key
  LEFT JOIN seller_reviews srev       ON ds.seller_key = srev.seller_key
  LEFT JOIN seller_item_anomalies sia  ON ds.seller_key = sia.seller_key
  LEFT JOIN seller_order_anomalies soa ON ds.seller_key = soa.seller_key
  LEFT JOIN seller_delivery sd         ON ds.seller_key = sd.seller_key
)

SELECT * FROM seller_features_combined;


-- V1. Row count -- one row per seller, matching dim_seller exactly
SELECT
  (SELECT COUNT(*) FROM `olist-analytics-500708.olist_serving.dim_seller`) AS dim_seller_count,
  (SELECT COUNT(*) FROM `olist-analytics-500708.olist_analytics.seller_features`) AS feature_table_count;

-- V2. Duplicate check
SELECT COUNT(*) AS total_rows, COUNT(DISTINCT seller_key) AS distinct_keys
FROM `olist-analytics-500708.olist_analytics.seller_features`;

-- V3. Null checks on required columns
SELECT
  COUNTIF(seller_key IS NULL) AS null_key,
  COUNTIF(total_orders IS NULL) AS null_orders,
  COUNTIF(total_items IS NULL) AS null_items
FROM `olist-analytics-500708.olist_analytics.seller_features`;

-- V4. Aggregation reconciliation
SELECT
  (SELECT SUM(total_items) FROM `olist-analytics-500708.olist_analytics.seller_features`) AS summed_items,
  (SELECT COUNT(*) FROM `olist-analytics-500708.olist_serving.fact_order_item_fulfillment`) AS fact_row_count;

-- Revenue reconciliation: total across sellers must match fact table
SELECT
  (SELECT SUM(price) FROM `olist-analytics-500708.olist_serving.fact_order_item_fulfillment`) AS fact_total,
  (SELECT SUM(total_revenue) FROM `olist-analytics-500708.olist_analytics.seller_features`) AS seller_total;

-- V5. Rate bounds -- every rate must be 0-1 or NULL
SELECT COUNT(*) AS bad_rate_rows
FROM `olist-analytics-500708.olist_analytics.seller_features`
WHERE late_delivery_rate NOT BETWEEN 0 AND 1
   OR order_level_anomaly_rate NOT BETWEEN 0 AND 1
   OR item_level_anomaly_rate NOT BETWEEN 0 AND 1;

-- V6. Denominator validation
SELECT COUNT(*) AS logic_violations
FROM `olist-analytics-500708.olist_analytics.seller_features`
WHERE delivered_order_count > total_orders;

-- V8. Rate-to-count reconciliation -- every rate must be exactly
-- reproducible from its own stored count and correct denominator
SELECT COUNT(*) AS mismatched_rate_calculations
FROM `olist-analytics-500708.olist_analytics.seller_features`
WHERE total_items > 0 AND total_orders > 0
  AND (
    ROUND(item_level_anomaly_rate, 6) != ROUND(SAFE_DIVIDE(shipping_anomaly_count, total_items), 6)
    OR ROUND(order_level_anomaly_rate, 6) != ROUND(SAFE_DIVIDE(order_level_anomalous_order_count, total_orders), 6)
    OR ROUND(late_delivery_rate, 6) != ROUND(SAFE_DIVIDE(late_delivery_count, delivered_order_count), 6)
  );

-- V9. Sample-size flags are not identical across the board
SELECT COUNTIF(has_sufficient_sample_size != has_sufficient_delivery_sample_size) AS sellers_where_flags_differ
FROM `olist-analytics-500708.olist_analytics.seller_features`;

-- V10. Grain-attribution spot check -- confirm order_level_anomaly_rate
-- and item_level_anomaly_rate are NOT proxies for each other (they
-- should NOT be highly correlated 1:1, since they measure different
-- attribution units)
SELECT CORR(item_level_anomaly_rate, order_level_anomaly_rate) AS correlation
FROM `olist-analytics-500708.olist_analytics.seller_features`
WHERE item_level_anomaly_rate IS NOT NULL AND order_level_anomaly_rate IS NOT NULL;
-- A correlation near 1.0 would suggest the two metrics collapsed into
-- redundancy; a moderate/low correlation confirms they capture
-- genuinely distinct signals, as designed.

SELECT
MIN(item_level_anomaly_rate),
MAX(item_level_anomaly_rate),
AVG(item_level_anomaly_rate),
STDDEV(item_level_anomaly_rate)
FROM  `olist-analytics-500708.olist_analytics.seller_features`

SELECT
MIN(order_level_anomaly_rate),
MAX(order_level_anomaly_rate),
AVG(order_level_anomaly_rate),
STDDEV(order_level_anomaly_rate)
FROM `olist-analytics-500708.olist_analytics.seller_features`;

SELECT
COUNTIF(item_level_anomaly_rate > 0),
COUNTIF(order_level_anomaly_rate > 0)
FROM `olist-analytics-500708.olist_analytics.seller_features`;

SELECT
APPROX_QUANTILES(item_level_anomaly_rate,10),
APPROX_QUANTILES(order_level_anomaly_rate,10)
FROM `olist-analytics-500708.olist_analytics.seller_features`;








