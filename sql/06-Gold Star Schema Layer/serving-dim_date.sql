-- =====================================================================
-- serving LAYER: dim_date
-- Source: olist_clean.orders (read-only, boundary determination only --
--          no per-row dependency; this table has zero grain
--          relationship to any Clean Layer table).
-- Grain: one row per calendar date.
-- Range: MIN(order_purchase_timestamp) to MAX(order_estimated_delivery_date),
--        exactly as specified -- no arbitrary buffer applied.
-- =====================================================================

CREATE OR REPLACE TABLE `olist-analytics-500708.olist_serving.dim_date`
AS
WITH
  date_bounds AS (
    SELECT
      DATE(MIN(order_purchase_timestamp)) AS min_date,
      DATE(MAX(order_estimated_delivery_date)) AS max_date
    FROM `olist-analytics-500708.olist_clean.orders`
  ),
  date_spine AS (
    SELECT full_date
    FROM
      date_bounds,  -- this means cross join
      UNNEST(GENERATE_DATE_ARRAY(min_date, max_date, INTERVAL 1 DAY))
        AS full_date
  )
SELECT
  -- Deterministic surrogate key: YYYYMMDD as integer.
  CAST(FORMAT_DATE('%Y%m%d', full_date) AS INT64) AS date_key,
  full_date,
  EXTRACT(YEAR FROM full_date) AS year,
  EXTRACT(QUARTER FROM full_date) AS quarter,
  EXTRACT(MONTH FROM full_date) AS month,
  FORMAT_DATE('%B', full_date) AS month_name,

  -- ISO week number. BigQuery's default EXTRACT(WEEK) is
  -- Sunday-starting and non-ISO; ISOWEEK is used here as the more
  -- standard, unambiguous convention for a "week_of_year" business
  -- attribute.
  EXTRACT(ISOWEEK FROM full_date) AS week_of_year,
  EXTRACT(DAY FROM full_date) AS day_of_month,

  -- day_of_week: BigQuery's EXTRACT(DAYOFWEEK) returns 1=Sunday..7=Saturday.
  EXTRACT(DAYOFWEEK FROM full_date) AS day_of_week,
  FORMAT_DATE('%A', full_date) AS day_name,

  -- is_weekend: derived directly from day_of_week's convention above
  -- (1=Sunday, 7=Saturday) rather than re-deriving from full_date, to
  -- keep the two columns guaranteed consistent with each other.
  EXTRACT(DAYOFWEEK FROM full_date) IN (1, 7) AS is_weekend
FROM date_spine
ORDER BY full_date;

-- V1. Row count -- must exactly match calendar day count in range
SELECT
  COUNT(*) AS actual_row_count,
  DATE_DIFF(MAX(full_date), MIN(full_date), DAY) + 1 AS expected_row_count
FROM `olist-analytics-500708.olist_serving.dim_date`;
-- Expected: equal

-- V2. Duplicate check
SELECT
  COUNT(*) AS total_rows,
  COUNT(DISTINCT date_key) AS distinct_keys,
  COUNT(DISTINCT full_date) AS distinct_dates
FROM `olist-analytics-500708.olist_serving.dim_date`;
-- Expected: all three equal

-- V3. Primary key validation
SELECT COUNT(*) AS null_or_dup_keys
FROM
  (
    SELECT date_key
    FROM `olist-analytics-500708.olist_serving.dim_date`
    WHERE date_key IS NULL
    GROUP BY date_key
    HAVING COUNT(*) > 1
  );
-- Expected: 0

-- V4. Business validation -- confirm exact boundary alignment with the
-- two specified source columns (no buffer means these should match
-- min_date/max_date exactly, not just "cover" them)
SELECT
  (SELECT MIN(full_date) FROM `olist-analytics-500708.olist_serving.dim_date`)
    AS dim_min,
  (
    SELECT DATE(MIN(order_purchase_timestamp))
    FROM `olist-analytics-500708.olist_clean.orders`
  ) AS source_min,
  (SELECT MAX(full_date) FROM `olist-analytics-500708.olist_serving.dim_date`)
    AS dim_max,
  (
    SELECT DATE(MAX(order_estimated_delivery_date))
    FROM `olist-analytics-500708.olist_clean.orders`
  ) AS source_max;
-- Expected: dim_min = source_min, dim_max = source_max exactly

-- V5. Coverage check against ALL date columns fact tables will join on
-- (not just the two boundary columns) -- this is the critical test,
-- since no buffer was applied and other date columns could fall
-- outside the range defined by only these two)
SELECT COUNT(*) AS unmatched_approved_dates
FROM `olist-analytics-500708.olist_clean.orders` o
LEFT JOIN `olist-analytics-500708.olist_serving.dim_date` d
  ON DATE(o.order_approved_at) = d.full_date
WHERE d.full_date IS NULL AND o.order_approved_at IS NOT NULL;

SELECT COUNT(*) AS unmatched_carrier_dates
FROM `olist-analytics-500708.olist_clean.orders` o
LEFT JOIN `olist-analytics-500708.olist_serving.dim_date` d
  ON DATE(o.order_delivered_carrier_date) = d.full_date
WHERE d.full_date IS NULL AND o.order_delivered_carrier_date IS NOT NULL;

SELECT COUNT(*) AS unmatched_delivered_dates
FROM `olist-analytics-500708.olist_clean.orders` o
LEFT JOIN `olist-analytics-500708.olist_serving.dim_date` d
  ON DATE(o.order_delivered_customer_date) = d.full_date
WHERE d.full_date IS NULL AND o.order_delivered_customer_date IS NOT NULL;
-- Expected: all 0. If any is non-zero, this is a real, structural
-- finding -- not a formality -- see Common Mistakes below.

-- V6. Attribute consistency checks
SELECT COUNT(*) AS inconsistent_rows
FROM `olist-analytics-500708.olist_serving.dim_date`
WHERE
  year != EXTRACT(YEAR FROM full_date)
  OR quarter != EXTRACT(QUARTER FROM full_date)
  OR month != EXTRACT(MONTH FROM full_date)
  OR day_of_month != EXTRACT(DAY FROM full_date);
-- Expected: 0

-- V7. is_weekend / day_of_week logical consistency
SELECT COUNT(*) AS inconsistent_weekend_flags
FROM `olist-analytics-500708.olist_serving.dim_date`
WHERE is_weekend != (day_of_week IN (1, 7));
-- Expected: 0
