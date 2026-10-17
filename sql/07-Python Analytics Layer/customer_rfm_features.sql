-- =====================================================================
-- ANALYTICAL DATASET: customer_rfm_features
-- Objective 4: Customer Value Segmentation (RFM)
--
-- Purpose: one trusted row per CUSTOMER (person) holding their real
--          purchasing behaviour -- recency, frequency, monetary value,
--          and whether they ever came back -- so the business can answer
--          the question that matters here: is retention a viable lever
--          for Olist, or is this structurally a one-time-purchase
--          marketplace where acquisition is the real game?
--
-- Source: serving LAYER ONLY --
--          serving.fact_order_item_fulfillment (orders, spend, purchase date key),
--          serving.dim_date (to recover the actual purchase DATE from the key),
--          serving.dim_customer (person key, region, first_purchase_category).
--
-- Grain: one row per customer_unique_id (person level), for customers
--        with at least one NON-CANCELLED, item-bearing order.
--        The serving fact's customer_key already points to the PERSON (it
--        was resolved through dim_customer, which is person-grain), so
--        person-level R/F/M is a clean GROUP BY customer_key -- the direct
--        payoff of the dim_customer grain decision.
--
-- APPROVED ANALYTICAL DECISIONS (documented, not defaults):
--   - PURCHASE POPULATION = non-cancelled orders. Cancelled orders are
--     not realized purchases (customer backed out), so they are excluded
--     from R, F and M. All three are computed over the SAME set so they
--     describe the same purchases. (Unavailable orders have no line items
--     and therefore never reach the fact anyway.)
--   - MONETARY = SUM(price + freight_value) = the total the customer paid.
--   - RECENCY REFERENCE = a FIXED snapshot date (the last purchase date in
--     the data), because this is a static historical dataset -- a live
--     "today" would be meaningless. Same fixed-anchor logic as seller tenure.
--   - FREQUENCY IS NOT SCORED. 96.88% of customers buy exactly once, so a
--     frequency quintile would be meaningless. Frequency is represented
--     honestly by is_repeat_buyer; only recency and monetary (which have
--     real spread) get NTILE(5) scores. The final RFM SEGMENT and its
--     statistical validation are deferred to the Python/Statistics phase.
--
-- INHERITED ASSUMPTIONS FROM serving:
--   - first_purchase_category may be NULL (customers whose first order had
--     no items) -- carried through honestly, never back-filled.
--   - The snapshot date is the max purchase date among ITEM-BEARING orders
--     (the fact). It could be marginally earlier than the absolute raw max
--     if the very last order had no items -- a negligible, deliberate
--     trade-off to stay serving-only.
-- =====================================================================

CREATE OR REPLACE TABLE `olist-analytics-500708.olist_analytics.customer_rfm_features` AS

WITH purchases AS (
    -- The approved purchase population: non-cancelled, item-bearing orders,
  -- with the PERSON key, the actual purchase DATE, and the spend of each
  -- line item. We join dim_date because the fact carries only the date
  -- KEY (an integer YYYYMMDD), and recency needs a real DATE to diff.
  SELECT
  f.order_id, 
  f.customer_key,
   d.full_date AS order_purchase_date,
    f.price,
    f.freight_value
  FROM `olist-analytics-500708.olist_serving.fact_order_item_fulfillment` f
  JOIN `olist-analytics-500708.olist_serving.dim_date` d
    ON f.order_date_key = d.date_key
  WHERE f.order_status != 'canceled'
),

observation_window AS (
  -- The fixed snapshot date recency is measured against = the latest
  -- purchase date anywhere in the data (ALL item-bearing orders, any
  -- status, so cancelled orders still count as "we had data through then").
  -- One scalar, reused for every customer -- guarantees a reproducible
  -- recency on every rebuild, unlike CURRENT_DATE().
  SELECT MAX(d.full_date) AS snapshot_date
  FROM `olist-analytics-500708.olist_serving.fact_order_item_fulfillment` f
  JOIN `olist-analytics-500708.olist_serving.dim_date` d
    ON f.order_date_key = d.date_key
),

customer_rfm_raw AS (
  -- Aggregate the purchase population up to ONE row per person.
  -- frequency uses COUNT(DISTINCT order_id) so line items are not mistaken
  -- for orders. monetary SUMS every line item, because total spend is
  -- exactly the sum across items -- no de-duplication wanted here.

select
customer_key,
MIN(order_purchase_date)   AS first_order_date,
MAX(order_purchase_date)   AS last_order_date,
count(distinct order_id) as frequency,
sum(price + freight_value) as monetary
from purchases
group by customer_key
),

customer_rfm_metrics AS (
  -- Turn the raw aggregates into the RFM metrics and honest flags.
  -- recency_days = days from the customer's last purchase to the snapshot
  -- (lower = more recent). is_repeat_buyer is the honest frequency signal.
 SELECT
    r.customer_key,
    r.first_order_date,
    r.last_order_date,
  DATE_DIFF(ow.snapshot_date,r.last_order_date,DAY) AS recency_days,
  r.frequency,
    (r.frequency >= 2)                                    AS is_repeat_buyer,
    r.monetary,
    SAFE_DIVIDE(r.monetary, r.frequency)                  AS avg_order_value,
    DATE_DIFF(r.last_order_date, r.first_order_date, DAY) AS customer_lifespan_days
  from customer_rfm_raw r
  cross join observation_window ow
),

customer_rfm_scored AS (
  -- Add the two quintile scores. Only recency and monetary are scored,because only they have real spread.
  --   recency_score 5 = most recent  (ORDER BY recency_days DESC -> the smallest recency lands in tile 5)
  --   monetary_score 5 = highest spend (ORDER BY monetary ASC)
  -- Frequency is intentionally NOT scored
  SELECT
  m.*,
  NTILE(5) OVER(order by m.recency_days DESC) AS recency_score,
    NTILE(5) OVER (ORDER BY m.monetary ASC)      AS monetary_score
  FROM customer_rfm_metrics m
)

SELECT
s.customer_key,
  dc.customer_unique_id,
  dc.customer_state,
  dc.first_purchase_category,
   -- Cohort anchor: acquisition month for time-based cohort analysis.
  -- Enables "do customers from different periods retain differently?"
  -- Derived from first_order_date which is already computed above.
  -- FORMAT: YYYY-MM so cohorts sort chronologically as strings.
  FORMAT_DATE('%Y-%m', s.first_order_date) AS first_purchase_month,

  -- Recency
  s.recency_days,
  s.recency_score,

  -- Frequency
  s.frequency,
  s.is_repeat_buyer,

  -- Monetary
  s.monetary,
  s.monetary_score,
  s.avg_order_value,

  -- Supporting activity window
  s.first_order_date,
  s.last_order_date,
  s.customer_lifespan_days

FROM customer_rfm_scored s
-- INNER JOIN is safe: customer_key originates from the fact, which was
-- built through dim_customer, so every key resolves to exactly one person.
JOIN `olist-analytics-500708.olist_serving.dim_customer` dc
  ON s.customer_key = dc.customer_key;


-- ---------------------------------------------------------------------
-- V1. Row count reconciliation -- one row per customer who has at least
-- one non-cancelled, item-bearing order.
-- ---------------------------------------------------------------------
SELECT
  (SELECT COUNT(DISTINCT customer_key)
   FROM `olist-analytics-500708.olist_serving.fact_order_item_fulfillment`
   WHERE order_status != 'canceled') AS expected_customers,
  (SELECT COUNT(*)
   FROM `olist-analytics-500708.olist_analytics.customer_rfm_features`) AS feature_rows;
-- Expected: equal

-- ---------------------------------------------------------------------
-- V2. Grain + duplicate check -- exactly one row per person
-- ---------------------------------------------------------------------
SELECT
  COUNT(*)                          AS total_rows,
  COUNT(DISTINCT customer_key)      AS distinct_keys,
  COUNT(DISTINCT customer_unique_id) AS distinct_persons
FROM `olist-analytics-500708.olist_analytics.customer_rfm_features`;
-- Expected: all three equal

SELECT customer_key, COUNT(*) AS n
FROM `olist-analytics-500708.olist_analytics.customer_rfm_features`
GROUP BY customer_key HAVING COUNT(*) > 1;
-- Expected: 0 rows

-- ---------------------------------------------------------------------
-- V3. Aggregation reconciliation -- nothing double-counted or dropped
-- ---------------------------------------------------------------------
SELECT
  (SELECT ROUND(SUM(monetary), 2) FROM `olist-analytics-500708.olist_analytics.customer_rfm_features`) AS sum_monetary,
  (SELECT ROUND(SUM(price + freight_value), 2)
   FROM `olist-analytics-500708.olist_serving.fact_order_item_fulfillment`
   WHERE order_status != 'canceled') AS fact_gmv;
-- Expected: equal (total customer spend = total non-cancelled line-item value)

SELECT
  (SELECT SUM(frequency) FROM `olist-analytics-500708.olist_analytics.customer_rfm_features`) AS sum_frequency,
  (SELECT COUNT(DISTINCT order_id)
   FROM `olist-analytics-500708.olist_serving.fact_order_item_fulfillment`
   WHERE order_status != 'canceled') AS distinct_orders;
-- Expected: equal (each order belongs to exactly one person)

-- ---------------------------------------------------------------------
-- V4. RFM metric validation -- values must be logically possible
-- ---------------------------------------------------------------------
SELECT
  COUNTIF(recency_days < 0)              AS negative_recency,      -- 0 (last order <= snapshot)
  COUNTIF(frequency < 1)                 AS bad_frequency,         -- 0 (present => bought)
  COUNTIF(monetary <= 0)                 AS nonpositive_monetary,  -- 0 (price always > 0)
  COUNTIF(customer_lifespan_days < 0)    AS negative_lifespan,     -- 0
  COUNTIF(last_order_date < first_order_date) AS date_order_error  -- 0
FROM `olist-analytics-500708.olist_analytics.customer_rfm_features`;

-- ---------------------------------------------------------------------
-- V5. Score validation -- range, distinctness, direction, group balance
-- ---------------------------------------------------------------------
SELECT
  MIN(recency_score) AS min_r, MAX(recency_score) AS max_r,
  MIN(monetary_score) AS min_m, MAX(monetary_score) AS max_m,
  COUNT(DISTINCT recency_score) AS r_levels, COUNT(DISTINCT monetary_score) AS m_levels
FROM `olist-analytics-500708.olist_analytics.customer_rfm_features`;
-- Expected: 1..5 for both; 5 distinct levels each

SELECT recency_score, COUNT(*) AS n, MIN(recency_days) AS min_rd, MAX(recency_days) AS max_rd, ROUND(AVG(recency_days),1) AS avg_rd
FROM `olist-analytics-500708.olist_analytics.customer_rfm_features`
GROUP BY recency_score ORDER BY recency_score;
-- Expected: avg_rd DECREASES as score rises (5 = most recent); groups roughly equal

SELECT monetary_score, COUNT(*) AS n, ROUND(AVG(monetary),2) AS avg_monetary
FROM `olist-analytics-500708.olist_analytics.customer_rfm_features`
GROUP BY monetary_score ORDER BY monetary_score;
-- Expected: avg_monetary INCREASES as score rises (5 = highest spend)

-- ---------------------------------------------------------------------
-- V6. Null checks -- identity/RFM never null; first_purchase_category MAY be
-- ---------------------------------------------------------------------
SELECT
  COUNTIF(customer_key IS NULL)         AS null_key,
  COUNTIF(customer_unique_id IS NULL)   AS null_uid,
  COUNTIF(customer_state IS NULL)       AS null_state,
  COUNTIF(recency_days IS NULL)         AS null_recency,
  COUNTIF(frequency IS NULL)            AS null_frequency,
  COUNTIF(monetary IS NULL)             AS null_monetary,
  COUNTIF(recency_score IS NULL)        AS null_r_score,
  COUNTIF(monetary_score IS NULL)       AS null_m_score,
  COUNTIF(avg_order_value IS NULL)      AS null_aov,
  COUNTIF(first_purchase_category IS NULL) AS null_first_category
FROM `olist-analytics-500708.olist_analytics.customer_rfm_features`;
-- Expected: all 0 except null_first_category (inherited; reconcile against dim_customer)

-- ---------------------------------------------------------------------
-- V7. Business logic validation
-- ---------------------------------------------------------------------
SELECT
  COUNTIF(is_repeat_buyer != (frequency >= 2)) AS repeat_flag_error, -- 0
  COUNTIF(ROUND(avg_order_value, 4) != ROUND(monetary / frequency, 4)) AS aov_error -- 0
FROM `olist-analytics-500708.olist_analytics.customer_rfm_features`;

SELECT
  COUNTIF(is_repeat_buyer) AS repeat_customers,
  COUNT(*)                 AS total_customers,
  ROUND(COUNTIF(is_repeat_buyer) / COUNT(*) * 100, 2) AS repeat_rate_pct
FROM `olist-analytics-500708.olist_analytics.customer_rfm_features`;
-- Expected: repeat_rate_pct near ~3% (mirrors the 96.88% one-time finding)

-- ---------------------------------------------------------------------
-- V8. Distribution sanity checks
-- ---------------------------------------------------------------------
SELECT frequency, COUNT(*) AS n
FROM `olist-analytics-500708.olist_analytics.customer_rfm_features`
GROUP BY frequency ORDER BY frequency LIMIT 20;
-- Expected: frequency = 1 holds ~97% of customers

SELECT
  APPROX_QUANTILES(monetary, 4) AS monetary_quartiles,
  ROUND(AVG(monetary), 2)       AS mean_monetary,
  MAX(monetary)                 AS max_monetary
FROM `olist-analytics-500708.olist_analytics.customer_rfm_features`;
-- Expected: right-skewed -- mean noticeably above the median (Q2)

SELECT APPROX_QUANTILES(recency_days, 4) AS recency_quartiles
FROM `olist-analytics-500708.olist_analytics.customer_rfm_features`;
-- Expected: spread across the ~2-year window, not clustered at one value

-- ---------------------------------------------------------------------
-- V9. Spot checks
-- ---------------------------------------------------------------------
SELECT customer_unique_id, frequency, monetary, avg_order_value,
       recency_days, recency_score, monetary_score, first_order_date, last_order_date
FROM `olist-analytics-500708.olist_analytics.customer_rfm_features`
WHERE is_repeat_buyer
ORDER BY frequency DESC, monetary DESC
LIMIT 20;
-- Eyeball: top repeat buyers should read coherently (multiple orders,
-- higher spend, sensible date span).

SELECT MAX(last_order_date) AS latest_customer_order
FROM `olist-analytics-500708.olist_analytics.customer_rfm_features`;
-- Sanity: should equal the dataset's known max purchase date (~2018-10-17).


