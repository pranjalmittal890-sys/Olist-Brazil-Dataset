-- =====================================================================
-- serving LAYER: data_quality_flags (junk dimension)
-- Source: olist_clean.orders, olist_clean.order_items (Clean Layer only)
-- Grain: one row per DISTINCT combination of the six approved fulfillment
--          anomaly flags actually observed in the data. Previously
--          validated at exactly 6 distinct combinations -- this build
--          enumerates them directly from source rather than
--          hardcoding, so the table stays correct if source data changes.
-- Excluded per approved scope: payment anomalies, review anomalies,
--          ETL/imputation flags.
-- =====================================================================

CREATE OR REPLACE TABLE `olist-analytics-500708.olist_serving.data_quality_flags` AS

WITH item_level_flags AS (
  -- Build the flag combination at ITEM grain, since that's the grain
  -- fact_order_item_fulfillment will join against. Order-level flags
  -- (from orders) are denormalized onto every item row of that order;
  -- the one item-native flag (shipping anomaly) already lives at this
  -- grain natively in order_items.
  SELECT DISTINCT
    o.is_delivery_before_carrier_anomaly,
    o.is_delivered_missing_approval_anomaly,
    o.is_delivered_missing_multiple_dates_anomaly,
    o.is_carrier_before_approval_anomaly,
    o.is_canceled_with_delivery_date_anomaly,
    oi.is_shipping_date_anomaly AS is_shipping_anomaly
  FROM `olist-analytics-500708.olist_clean.order_items` oi
  INNER JOIN `olist-analytics-500708.olist_clean.orders` o
    ON oi.order_id = o.order_id
)

SELECT
  -- Surrogate key, deterministic ordering across all six flag columns
  -- for reproducibility across rebuilds.
  ROW_NUMBER() OVER (
    ORDER BY
      is_delivery_before_carrier_anomaly,
      is_delivered_missing_approval_anomaly,
      is_delivered_missing_multiple_dates_anomaly,
      is_carrier_before_approval_anomaly,
      is_canceled_with_delivery_date_anomaly,
      is_shipping_anomaly
  ) AS data_quality_key,

  is_delivery_before_carrier_anomaly,
  is_delivered_missing_approval_anomaly,
  is_delivered_missing_multiple_dates_anomaly,
  is_carrier_before_approval_anomaly,
  is_canceled_with_delivery_date_anomaly,
  is_shipping_anomaly

FROM item_level_flags;

-- V1. Confirm exactly 6 distinct combinations, as previously validated
SELECT COUNT(*) AS combination_count
FROM `olist-analytics-500708.olist_serving.data_quality_flags`;
-- Expected: 6

-- V2. Primary key validation
SELECT COUNT(*) AS total_rows, COUNT(DISTINCT data_quality_key) AS distinct_keys
FROM `olist-analytics-500708.olist_serving.data_quality_flags`;
-- Expected: equal

-- V3. No duplicate flag combinations (the actual uniqueness guarantee
-- the dimension depends on, distinct from key uniqueness)
SELECT
  is_delivery_before_carrier_anomaly, is_delivered_missing_approval_anomaly,
  is_delivered_missing_multiple_dates_anomaly, is_carrier_before_approval_anomaly,
  is_canceled_with_delivery_date_anomaly, is_shipping_anomaly,
  COUNT(*) AS n
FROM `olist-analytics-500708.olist_serving.data_quality_flags`
GROUP BY 1,2,3,4,5,6
HAVING COUNT(*) > 1;
-- Expected: 0 rows returned

-- V4. THE CRITICAL CHECK -- every fact-grain row (order_item) must map
-- to EXACTLY ONE junk dimension row. This is the check that actually
-- validates the junk dimension will work as a fact table foreign key,
-- not just that it's internally well-formed.
WITH fact_grain_flags AS (
  SELECT
    oi.order_id,
    oi.order_item_id,
    o.is_delivery_before_carrier_anomaly,
    o.is_delivered_missing_approval_anomaly,
    o.is_delivered_missing_multiple_dates_anomaly,
    o.is_carrier_before_approval_anomaly,
    o.is_canceled_with_delivery_date_anomaly,
    oi.is_shipping_date_anomaly AS is_shipping_anomaly
  FROM `olist-analytics-500708.olist_clean.order_items` oi
  INNER JOIN `olist-analytics-500708.olist_clean.orders` o
    ON oi.order_id = o.order_id
)
SELECT COUNT(*) AS unmatched_fact_rows
FROM fact_grain_flags f
LEFT JOIN `olist-analytics-500708.olist_serving.data_quality_flags` dqf
  ON f.is_delivery_before_carrier_anomaly = dqf.is_delivery_before_carrier_anomaly
  AND f.is_delivered_missing_approval_anomaly = dqf.is_delivered_missing_approval_anomaly
  AND f.is_delivered_missing_multiple_dates_anomaly = dqf.is_delivered_missing_multiple_dates_anomaly
  AND f.is_carrier_before_approval_anomaly = dqf.is_carrier_before_approval_anomaly
  AND f.is_canceled_with_delivery_date_anomaly = dqf.is_canceled_with_delivery_date_anomaly
  AND f.is_shipping_anomaly = dqf.is_shipping_anomaly
WHERE dqf.data_quality_key IS NULL;
-- Expected: 0. If this returns non-zero, the dimension is missing at
-- least one combination that actually exists at fact grain -- would
-- indicate a genuine bug (e.g. a NULL-vs-NULL join mismatch, since
-- BigQuery's equality join treats NULL = NULL as unmatched, and these
-- flags are stated as BOOL NOT NULL in Silver -- worth explicit
-- confirmation, not assumption, given how much scrutiny nulls have
-- gotten throughout this project).

-- V5. Confirm every row's total row count reconciles -- combination
-- set built from fact-grain data should have the SAME total underlying
-- row coverage as order_items itself
SELECT
  (SELECT COUNT(*) FROM `olist-analytics-500708.olist_clean.order_items`) AS total_order_items,
  (SELECT COUNT(*)
   FROM `olist-analytics-500708.olist_clean.order_items` oi
   INNER JOIN `olist-analytics-500708.olist_clean.orders` o ON oi.order_id = o.order_id
  ) AS joined_row_count;
-- Expected: equal (confirms the INNER JOIN didn't silently drop rows)



