-- =====================================================================
-- serving LAYER: dim_seller (updated per confirmed parameters)
-- Source: olist_clean.sellers, olist_clean.order_items, olist_clean.orders
--          (Clean Layer only)
-- Grain: one row per seller_id.
-- Confirmed logic:
--   - seller_tenure_bucket: 90-day threshold, relative to dataset max
--     purchase date (confirmed, unchanged)
--   - seller_volume_tier: NTILE(3) over COUNT(DISTINCT order_id) --
--     i.e. distinct customer orders fulfilled, NOT line-item count.
--     Deliberately different from the primary fact table's item grain:
--     "how many orders did this seller fulfill" is the business
--     question, not "how many units did they ship" -- a seller with
--     one large multi-item order should not rank as high-volume on
--     that basis alone.
-- =====================================================================

CREATE OR REPLACE TABLE `olist-analytics-500708.olist_serving.dim_seller` AS

WITH max_purchase_date AS (
  SELECT MAX(order_purchase_timestamp) AS max_ts
  FROM `olist-analytics-500708.olist_clean.orders`
),

seller_first_order AS (
  SELECT
    oi.seller_id,
    MIN(o.order_purchase_timestamp) AS first_order_ts
  FROM `olist-analytics-500708.olist_clean.order_items` oi
  INNER JOIN `olist-analytics-500708.olist_clean.orders` o
    ON oi.order_id = o.order_id
  GROUP BY oi.seller_id
),

seller_order_volume AS (
  -- CHANGED: COUNT(DISTINCT order_id) instead of COUNT(*). A seller
  -- with 1 order containing 10 items now correctly counts as 1 order
  -- fulfilled, not 10. This is the confirmed, correct basis for a
  -- seller-level (not item-level) business measure.
  SELECT
    seller_id,
    COUNT(DISTINCT order_id) AS order_count
  FROM `olist-analytics-500708.olist_clean.order_items`
  GROUP BY seller_id
),

seller_tenure AS (
  SELECT
    sfo.seller_id,
    -- 90-day threshold confirmed as an intentional business rule.
    CASE
      WHEN DATE_DIFF(DATE(mpd.max_ts), DATE(sfo.first_order_ts), DAY) <= 90
        THEN 'new'
      ELSE 'established'
    END AS seller_tenure_bucket
  FROM seller_first_order sfo
  CROSS JOIN max_purchase_date mpd
),

seller_volume_tiered AS (
  SELECT
    seller_id,
    order_count,
    -- NTILE(3) now ordered on distinct order_count.
    NTILE(3) OVER (ORDER BY order_count ASC) AS volume_ntile
  FROM seller_order_volume
),

seller_volume_labeled AS (
  SELECT
    seller_id,
    CASE volume_ntile
      WHEN 1 THEN 'low'
      WHEN 2 THEN 'medium'
      WHEN 3 THEN 'high'
    END AS seller_volume_tier
  FROM seller_volume_tiered
)

SELECT
  ROW_NUMBER() OVER (ORDER BY s.seller_id) AS seller_key,
  s.seller_id,
  s.seller_city,
  s.seller_state,
  st.seller_tenure_bucket,
  svl.seller_volume_tier

FROM `olist-analytics-500708.olist_clean.sellers` s
LEFT JOIN seller_tenure st
  ON s.seller_id = st.seller_id
LEFT JOIN seller_volume_labeled svl
  ON s.seller_id = svl.seller_id;

-- V1. Row count -- must equal distinct seller_id count in Silver
SELECT
  (SELECT COUNT(DISTINCT seller_id) FROM `olist-analytics-500708.olist_clean.sellers`) AS silver_count,
  (SELECT COUNT(*) FROM `olist-analytics-500708.olist_serving.dim_seller`) AS serving_count;
-- Expected: equal

-- V2. Primary key validation
SELECT COUNT(*) AS total_rows, COUNT(DISTINCT seller_key) AS distinct_keys,
       COUNT(DISTINCT seller_id) AS distinct_natural_keys
FROM `olist-analytics-500708.olist_serving.dim_seller`;
-- Expected: all three equal

-- V3. Null checks -- flags sellers with no order-item history, if any
SELECT
  COUNTIF(seller_tenure_bucket IS NULL) AS sellers_without_tenure,
  COUNTIF(seller_volume_tier IS NULL)   AS sellers_without_volume_tier
FROM `olist-analytics-500708.olist_serving.dim_seller`;
-- If either is > 0: these are sellers with zero order-items -- verify
-- this is a real, expected condition (a registered seller who never
-- sold anything) rather than a join error, before accepting it.

-- V4. Tenure bucket sanity check -- confirm the reference date used
-- matches the true dataset maximum
SELECT MAX(order_purchase_timestamp) AS true_max_purchase_date
FROM `olist-analytics-500708.olist_clean.orders`;
-- Manually compare against the max_ts value the script computed;
-- should be identical.

-- V5. Volume tier distribution -- confirm roughly equal thirds
-- (NTILE(3) balances as evenly as row count allows)
SELECT seller_volume_tier, COUNT(*) AS n
FROM `olist-analytics-500708.olist_serving.dim_seller`
GROUP BY seller_volume_tier
ORDER BY seller_volume_tier;
-- Expected: three roughly equal groups (off-by-one differences are
-- normal if seller_id count isn't evenly divisible by 3)

-- V6. Tenure bucket distribution -- sanity check, not a pass/fail test
SELECT seller_tenure_bucket, COUNT(*) AS n
FROM `olist-analytics-500708.olist_serving.dim_seller`
GROUP BY seller_tenure_bucket;

-- V7 (updated). Cross-check: 'high' tier should correspond to sellers
-- with materially higher DISTINCT ORDER counts than 'low' -- catches
-- an inverted NTILE ordering mistake, now on the correct basis
SELECT
  d.seller_volume_tier,
  MIN(v.order_count) AS min_orders,
  MAX(v.order_count) AS max_orders,
  AVG(v.order_count) AS avg_orders
FROM `olist-analytics-500708.olist_serving.dim_seller` d
JOIN (
  SELECT seller_id, COUNT(DISTINCT order_id) AS order_count
  FROM `olist-analytics-500708.olist_clean.order_items`
  GROUP BY seller_id
) v ON d.seller_id = v.seller_id
GROUP BY d.seller_volume_tier
ORDER BY avg_orders;
-- Expected: low < medium < high, monotonically increasing



