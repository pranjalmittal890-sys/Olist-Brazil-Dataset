-- =====================================================================
-- ANALYTICAL DATASET: order_delivery_features
-- Objective: Delivery & Operations Reliability
-- Purpose: one trusted row per ORDER that carries every signal needed to answer "where and why does our delivery promise break down"
-- the two stage durations, the on-time outcome, the size of the miss, the customer/seller geography for cross-region analysis,
-- and the delivery-data trust flag. Built once so Python,statistics, and the dashboard all read the same numbers.
-- Grain: one row per order_id.
-- Delivery is an ORDER-level event (the whole order ships and is delivered together), so we collapse the item-grain fact down to
-- one row per order. Building at item grain would count a 5-item order as 5 deliveries and over-weight big orders in every
-- regional average.
--
-- KNOWN LIMITATION (documented, not a bug): for the small number of orders that contain items from more than one seller, we pick a
-- PRIMARY SELLER (the seller of the highest-priced item). So primary_seller_state and is_cross_state are an approximation for
-- those orders. Seller-level late-delivery numbers should come from seller_features (which owns that question), NOT from this
-- table -- the two attribute multi-seller orders differently.
-- =====================================================================

CREATE OR REPLACE TABLE `olist-analytics-500708.olist_analytics.order_delivery_features` AS

WITH fact_with_flags AS (
  -- 7 order-level lifecycle flags only.
  -- Shipping anomaly (item-native) is excluded from this table because
  -- it is a seller reliability signal, not a delivery trust signal.
  SELECT
  f.order_id,
  f.order_status,
  f.customer_key,
  f.order_date_key,
  f.seller_key,
  f.price,
  f.freight_value,
  f.approval_to_carrier_hours,
  f.carrier_to_customer_days,
  f.is_delivered_on_time,
  f.delivery_estimate_error_days,
  f.product_key,
  dqf.is_delivered_missing_approval_anomaly,
    dqf.is_delivered_missing_multiple_dates_anomaly,
    dqf.is_carrier_before_approval_anomaly,
    dqf.is_delivery_before_carrier_anomaly,
    dqf.is_canceled_with_delivery_date_anomaly,
    dqf.is_delivered_missing_final_date_only,
    dqf.is_delivered_missing_carrier_anomaly
  from `olist-analytics-500708.olist_serving.fact_order_item_fulfillment` f
  left join `olist-analytics-500708.olist_serving.data_quality_flags` dqf
  using(data_quality_key)
),
-- ============================================================
-- Collapse item rows to order level. Revenue and freight are summed (item-level facts).
-- Delivery timing, status, review are order-level facts denormalized onto items — ANY_VALUE is safe because the value
-- is identical across all items of the same order.
-- ============================================================
order_level AS (
  SELECT
  order_id,
  ANY_VALUE(order_status)                    AS order_status,
    ANY_VALUE(customer_key)                    AS customer_key,
    ANY_VALUE(order_date_key)                  AS order_purchase_date_key,
    ANY_VALUE(approval_to_carrier_hours)       AS approval_to_carrier_hours,
    ANY_VALUE(carrier_to_customer_days)        AS carrier_to_customer_days,
    ANY_VALUE(is_delivered_on_time)            AS is_delivered_on_time,
    ANY_VALUE(delivery_estimate_error_days)    AS delivery_estimate_error_days,
     -- Revenue: sum of all item prices in this order
    ROUND(SUM(price), 2)                    AS order_total_revenue,

    -- Freight: sum of all item freight charges in this order
    ROUND(SUM(freight_value), 2)            AS order_total_freight,

    -- Freight as share of revenue — answers "how expensive was this
    -- order to ship relative to what the customer paid for goods?"
    ROUND(SAFE_DIVIDE(SUM(freight_value), NULLIF(SUM(price), 0)), 4)
                                            AS freight_to_revenue_ratio,

    -- Delivery data trust flag — TRUE if any lifecycle timestamp
    -- contradiction exists on this order. Drives the trust-rate KPI.
    LOGICAL_OR(
      is_delivered_missing_approval_anomaly
      OR is_delivered_missing_multiple_dates_anomaly
      OR is_carrier_before_approval_anomaly
      OR is_delivery_before_carrier_anomaly
      OR is_canceled_with_delivery_date_anomaly
      OR is_delivered_missing_final_date_only
      OR is_delivered_missing_carrier_anomaly
    )  AS has_delivery_timestamp_anomaly
  FROM fact_with_flags
  group by order_id
),
-- ============================================================
-- Primary seller per order: highest-priced item's seller. Deterministic tie-break on seller_key ASC.
-- Same logic used in original query — unchanged.
-- ============================================================
ranked_items AS (
  select order_id, seller_key, product_key, price,
  row_number() over(partition by order_id order by price desc, seller_key ASC) as price_rank
  from fact_with_flags
),

primary_seller_and_product AS (
  select order_id, 
  seller_key  AS primary_seller_key,
  product_key AS primary_product_key
  from ranked_items
  where price_rank = 1
),

final AS (
  SELECT
  ol.order_id,
  ol.order_status,

-- Helper: was the order actually delivered? Based on order_status, not on "does a delivery date exist," so the 6 
-- canceled-orders-that-carry-a-delivery-date anomalies are correctly treated as NOT delivered. This is the clean denominator base for the reliability
    (ol.order_status = 'delivered') AS is_delivered,

    -- Customer geography.
    ol.customer_key,
    dc.customer_state,
    dc.customer_city,

    -- Seller geography (primary seller approximation) - multi seller orders
    psp.primary_seller_key,
    ds.seller_state AS primary_seller_state,

   -- Cross-state flag: the key feature for geography analysis
    (dc.customer_state != ds.seller_state) AS is_cross_state,

    -- When the order started -- for trending by purchase month/quarter.
    ol.order_purchase_date_key,

    -- STAGE 1: seller / warehouse handoff speed (already in hours on Gold).
    ol.approval_to_carrier_hours,

    -- STAGE 2: last-mile / carrier speed (stored in whole DAYS on Gold).
    ol.carrier_to_customer_days,

    -- STAGE 2 restated in hours (days x 24) purely so the two stages can be compared on the same scale 
    (ol.carrier_to_customer_days * 24) AS carrier_to_customer_hours,

     -- Was it on time? NULL when never delivered -- never turned into FALSE.
    ol.is_delivered_on_time,

    -- BY HOW MUCH did we miss? Positive = late by N days, negative = early
    -- by N days, 0 = on the promised day, NULL = never delivered. This is
    -- the magnitude the boolean cannot give, and the reason we added the
    -- Gold column. It answers "are we over-promising, and by how much."
    ol.delivery_estimate_error_days,

  -- Revenue and cost
    ol.order_total_revenue,
    ol.order_total_freight,
    ol.freight_to_revenue_ratio,

    -- Product context: primary category of the highest-value item
    dp.category_name  AS primary_category,

  -- Can we trust this order's delivery data? TRUE if any of the five lifecycle-timestamp anomalies applies. Drives the "delivery data trust rate" KPI.
    ol.has_delivery_timestamp_anomaly

  from order_level ol
  left join primary_seller_and_product psp
  ON ol.order_id = psp.order_id
  LEFT JOIN `olist-analytics-500708.olist_serving.dim_customer` dc
    ON ol.customer_key = dc.customer_key
  LEFT JOIN `olist-analytics-500708.olist_serving.dim_seller` ds
    ON psp.primary_seller_key = ds.seller_key
  LEFT JOIN `olist-analytics-500708.olist_serving.dim_product` dp
    ON psp.primary_product_key = dp.product_key
)

SELECT * FROM final;

-- ---------------------------------------------------------------------
-- V1. Row count reconciliation -- one row per order that has items.
-- (RI-7 orders with no items are excluded by construction, correctly.)
-- ---------------------------------------------------------------------
SELECT
  (SELECT COUNT(DISTINCT order_id) FROM `olist-analytics-500708.olist_serving.fact_order_item_fulfillment`) AS fact_distinct_orders,
  (SELECT COUNT(*) FROM `olist-analytics-500708.olist_analytics.order_delivery_features`) AS feature_rows;
-- Expected: equal (~98,666 = 99,441 total orders minus 775 no-item orders)

-- ---------------------------------------------------------------------
-- V2. Duplicate + grain check -- exactly one row per order_id
-- ---------------------------------------------------------------------
SELECT COUNT(*) AS total_rows, COUNT(DISTINCT order_id) AS distinct_orders
FROM `olist-analytics-500708.olist_analytics.order_delivery_features`;
-- Expected: equal

SELECT order_id, COUNT(*) AS n
FROM `olist-analytics-500708.olist_analytics.order_delivery_features`
GROUP BY order_id HAVING COUNT(*) > 1;
-- Expected: 0 rows

-- ---------------------------------------------------------------------
-- V3. Null validation -- columns that must never be null, and the
-- outcome columns that must be null TOGETHER
-- ---------------------------------------------------------------------
SELECT
  COUNTIF(order_id IS NULL)              AS null_order_id,
  COUNTIF(order_status IS NULL)          AS null_status,
  COUNTIF(customer_state IS NULL)        AS null_customer_state,
  COUNTIF(primary_seller_state IS NULL)  AS null_seller_state,
  COUNTIF(is_cross_state IS NULL)        AS null_cross_state,
  COUNTIF((is_delivered_on_time IS NULL) != (delivery_estimate_error_days IS NULL)) AS outcome_null_mismatch
FROM `olist-analytics-500708.olist_analytics.order_delivery_features`;
-- Expected: first five = 0; outcome_null_mismatch = 0

-- ---------------------------------------------------------------------
-- V4. Denominator validation -- the reliability rate must exclude the
-- canceled-with-delivery-date anomalies (is_delivered = FALSE even though
-- an on-time value exists)
-- ---------------------------------------------------------------------
SELECT
  COUNTIF(is_delivered = FALSE AND is_delivered_on_time IS NOT NULL) AS canceled_with_outcome, -- expect ~6
  COUNTIF(is_delivered AND is_delivered_on_time IS NOT NULL)         AS reliability_denominator,
  COUNTIF(is_delivered AND is_delivered_on_time = TRUE)              AS on_time_numerator
FROM `olist-analytics-500708.olist_analytics.order_delivery_features`;
-- Expected: canceled_with_outcome is small (the 6 anomalies), and it is
-- NOT part of the denominator above -- confirming the correct base.

-- ---------------------------------------------------------------------
-- V5. Delivery estimate error validation -- sign must agree with the
-- on-time flag; the only allowed disagreement is same-day (error = 0)
-- ---------------------------------------------------------------------
SELECT
  COUNTIF(delivery_estimate_error_days > 0 AND is_delivered_on_time = TRUE)  AS impossible_late_ontime,  -- expect 0
  COUNTIF(delivery_estimate_error_days < 0 AND is_delivered_on_time = FALSE) AS impossible_early_late,    -- expect 0
  COUNTIF(delivery_estimate_error_days = 0 AND is_delivered_on_time = FALSE) AS same_day_boundary          -- small, explainable
FROM `olist-analytics-500708.olist_analytics.order_delivery_features`;

-- ---------------------------------------------------------------------
-- V6. Stage duration validation -- negative durations must always be
-- flagged anomalies, and the hours restatement must be exact
-- ---------------------------------------------------------------------
SELECT
  COUNTIF(approval_to_carrier_hours < 0) AS negative_stage1,
  COUNTIF(carrier_to_customer_days < 0)  AS negative_stage2,
  COUNTIF((approval_to_carrier_hours < 0 OR carrier_to_customer_days < 0)
          AND has_delivery_timestamp_anomaly = FALSE) AS negative_but_not_flagged,  -- expect 0
  COUNTIF(carrier_to_customer_hours != carrier_to_customer_days * 24) AS unit_mismatch -- expect 0
FROM `olist-analytics-500708.olist_analytics.order_delivery_features`;

-- ---------------------------------------------------------------------
-- V7. Cross-state validation -- logic and distribution
-- ---------------------------------------------------------------------
SELECT COUNTIF(is_cross_state != (customer_state != primary_seller_state)) AS cross_state_logic_error -- expect 0
FROM `olist-analytics-500708.olist_analytics.order_delivery_features`;

SELECT is_cross_state, COUNT(*) AS n
FROM `olist-analytics-500708.olist_analytics.order_delivery_features`
GROUP BY is_cross_state;
-- Sanity: cross-state should be the majority (Olist sellers concentrated
-- in SP shipping nationwide) -- confirm it's a believable split.

-- ---------------------------------------------------------------------
-- V8. Trust flag validation -- reconcile against the fact directly
-- ---------------------------------------------------------------------
SELECT
  (SELECT COUNT(DISTINCT f.order_id)
   FROM `olist-analytics-500708.olist_serving.fact_order_item_fulfillment` f
   JOIN `olist-analytics-500708.olist_serving.data_quality_flags` d
     ON f.data_quality_key = d.data_quality_key
   WHERE d.is_delivered_missing_approval_anomaly
      OR d.is_delivered_missing_multiple_dates_anomaly
      OR d.is_carrier_before_approval_anomaly
      OR d.is_delivery_before_carrier_anomaly
      OR d.is_canceled_with_delivery_date_anomaly) AS fact_anomaly_orders,
  (SELECT COUNTIF(has_delivery_timestamp_anomaly)
   FROM `olist-analytics-500708.olist_analytics.order_delivery_features`) AS feature_anomaly_orders;
-- Expected: equal

-- ---------------------------------------------------------------------
-- V9. is_delivered_on_time null count must match the fact at order grain
-- ---------------------------------------------------------------------
SELECT
  (SELECT COUNT(DISTINCT order_id)
   FROM `olist-analytics-500708.olist_serving.fact_order_item_fulfillment`
   WHERE is_delivered_on_time IS NULL) AS fact_null_orders,
  (SELECT COUNTIF(is_delivered_on_time IS NULL)
   FROM `olist-analytics-500708.olist_analytics.order_delivery_features`) AS feature_null_orders;
-- Expected: equal

-- ---------------------------------------------------------------------
-- V10. Distribution sanity checks
-- ---------------------------------------------------------------------
SELECT
  APPROX_QUANTILES(delivery_estimate_error_days, 4) AS error_quartiles,
  AVG(delivery_estimate_error_days) AS mean_error
FROM `olist-analytics-500708.olist_analytics.order_delivery_features`
WHERE delivery_estimate_error_days IS NOT NULL;
-- Expected: median NEGATIVE -- Olist's estimates are padded, so most
-- orders arrive early. A positive median would be a red flag to investigate.

SELECT
  APPROX_QUANTILES(approval_to_carrier_hours, 4) AS stage1_quartiles,
  avg(approval_to_carrier_hours) AS mean_stage1,
  APPROX_QUANTILES(carrier_to_customer_days, 4)  AS stage2_quartiles,
  avg(carrier_to_customer_days) AS mean_stage2
FROM `olist-analytics-500708.olist_analytics.order_delivery_features`
WHERE is_delivered;
-- Expected: both right-skewed (median well below the top quartile),
-- consistent with every other duration in this project.

-- ---------------------------------------------------------------------
-- V11. Business spot check -- pick one delivered order and eyeball it
-- ---------------------------------------------------------------------
SELECT *
FROM `olist-analytics-500708.olist_analytics.order_delivery_features`
WHERE is_delivered
ORDER BY delivery_estimate_error_days DESC
LIMIT 10;
-- Manually confirm the latest deliveries make sense: large positive
-- error_days, is_delivered_on_time = FALSE, sane stage durations.


SELECT
order_id
FROM `olist-analytics-500708.olist_serving.fact_order_item_fulfillment`
GROUP BY order_id
HAVING
COUNT(DISTINCT approval_to_carrier_hours) > 1
OR COUNT(DISTINCT carrier_to_customer_days) > 1
OR COUNT(DISTINCT is_delivered_on_time) > 1;


