-- =====================================================================
-- serving LAYER: dim_customer (updated per approved tie-break rule)
-- Source: olist_clean.customers, olist_clean.orders, olist_clean.order_items,
--          olist_clean.products (all Clean Layer only)
-- Grain: one row per customer_unique_id (person-level, NOT customer_id).
-- Approved logic:
--   - Address fields use "most recent order" per customer_unique_id
--   - first_purchase_category uses the customer's earliest order
--   - For multi-category first orders: highest-priced item's category
--     wins. Ties broken alphabetically by product_category_name as a
--     last-resort deterministic tie-break only.
--   - NULL is preserved when no line items exist for that first order --
--     never backfilled from a later order
-- =====================================================================

CREATE OR REPLACE TABLE `olist-analytics-500708.olist_serving.dim_customer` AS

WITH customer_orders AS (
  SELECT
    c.customer_unique_id,
    c.customer_id,
    c.customer_state,
    c.customer_city,
    c.customer_zip_code_prefix,
    o.order_id,
    o.order_purchase_timestamp
  FROM `olist-analytics-500708.olist_clean.customers` c
  INNER JOIN `olist-analytics-500708.olist_clean.orders` o
    ON c.customer_id = o.customer_id
),

ranked_most_recent AS (
  SELECT
    customer_unique_id,
    customer_state,
    customer_city,
    customer_zip_code_prefix,
    ROW_NUMBER() OVER (
      PARTITION BY customer_unique_id
      ORDER BY order_purchase_timestamp DESC, order_id DESC
    ) AS recency_rank
  FROM customer_orders
),

most_recent_address AS (
  SELECT
    customer_unique_id,
    customer_state,
    customer_city,
    customer_zip_code_prefix
  FROM ranked_most_recent
  WHERE recency_rank = 1
),

ranked_earliest_order AS (
  SELECT
    customer_unique_id,
    order_id,
    ROW_NUMBER() OVER (
      PARTITION BY customer_unique_id
      ORDER BY order_purchase_timestamp ASC, order_id ASC
    ) AS earliness_rank
  FROM customer_orders
),

earliest_order AS (
  SELECT customer_unique_id, order_id
  FROM ranked_earliest_order
  WHERE earliness_rank = 1
),

earliest_order_items AS (
  -- LEFT JOIN preserved from the prior version: a customer whose
  -- earliest order has no line items (RI-7 population) must still
  -- surface as a row here with NULL price/category, not be dropped.
  -- Now also carries price, since the tie-break rule needs it.
  SELECT
    eo.customer_unique_id,
    oi.price,
    p.product_category_name AS category
  FROM earliest_order eo
  LEFT JOIN `olist-analytics-500708.olist_clean.order_items` oi
    ON eo.order_id = oi.order_id
  LEFT JOIN `olist-analytics-500708.olist_clean.products` p
    ON oi.product_id = p.product_id
),

ranked_by_price_then_category AS (
  -- Primary sort: price DESC (highest-priced item wins -- the approved
  -- business rule). Secondary sort: category ASC, used ONLY to break
  -- genuine ties where two or more items share the exact same highest
  -- price within that order. This is now a fallback for a rare edge
  -- case, not the primary resolution mechanism it was before.
  SELECT
    customer_unique_id,
    category,
    price,
    ROW_NUMBER() OVER (
      PARTITION BY customer_unique_id
      ORDER BY price DESC, category ASC
    ) AS price_rank
  FROM earliest_order_items
),

final_first_category AS (
  SELECT customer_unique_id, category AS first_purchase_category
  FROM ranked_by_price_then_category
  WHERE price_rank = 1
)

SELECT
  ROW_NUMBER() OVER (ORDER BY mra.customer_unique_id) AS customer_key,
  mra.customer_unique_id,
  mra.customer_state,
  mra.customer_city,
  mra.customer_zip_code_prefix,
  ffc.first_purchase_category

FROM most_recent_address mra
LEFT JOIN final_first_category ffc
  ON mra.customer_unique_id = ffc.customer_unique_id;


-- V1. Row count -- must equal distinct customer_unique_id count in Silver
SELECT
  (SELECT COUNT(DISTINCT customer_unique_id) FROM `olist-analytics-500708.olist_clean.customers`) AS silver_distinct_persons,
  (SELECT COUNT(*) FROM `olist-analytics-500708.olist_serving.dim_customer`) AS serving_row_count;
-- Expected: equal

-- V2. Primary key validation
SELECT COUNT(*) AS total_rows, COUNT(DISTINCT customer_key) AS distinct_keys,
       COUNT(DISTINCT customer_unique_id) AS distinct_natural_keys
FROM `olist-analytics-500708.olist_serving.dim_customer`;
-- Expected: all three equal

-- V3. Null checks -- keys and address fields must never be null;
-- first_purchase_category MAY be null (approved behavior)
SELECT
  COUNTIF(customer_key IS NULL)               AS null_keys,
  COUNTIF(customer_unique_id IS NULL)         AS null_natural_keys,
  COUNTIF(customer_state IS NULL)             AS null_state,
  COUNTIF(customer_city IS NULL)              AS null_city,
  COUNTIF(customer_zip_code_prefix IS NULL)   AS null_zip,
  COUNTIF(first_purchase_category IS NULL)    AS null_first_category
FROM `olist-analytics-500708.olist_serving.dim_customer`;
-- Expected: first four = 0. null_first_category should be > 0 and,
-- ideally, cross-checked against the RI-7 no-line-item population size.

-- V4. Most-recent-address logic spot-check against the 122 known
-- multi-address customers
SELECT
  gc.customer_unique_id,
  gc.customer_state,
  gc.customer_city
FROM `olist-analytics-500708.olist_serving.dim_customer` gc
WHERE gc.customer_unique_id IN (
  -- substitute the actual flagged multi-address customer_unique_ids
  -- from Silver's has_multiple_addresses_on_record = TRUE population
  SELECT customer_unique_id
  FROM `olist-analytics-500708.olist_clean.customers`
  WHERE has_multiple_addresses_on_record = TRUE
)
LIMIT 20;
-- Manually verify a few against known order history -- confirm the
-- address shown matches that customer's MOST RECENT order, not an
-- arbitrary or first one.

-- V5. first_purchase_category null count should approximate (not
-- necessarily exactly equal, due to the multi-seller/category tiebreak
-- interaction) the count of customers whose EARLIEST order is in the
-- RI-7 no-line-item population
SELECT COUNT(*) AS customers_with_null_first_category
FROM `olist-analytics-500708.olist_serving.dim_customer`
WHERE first_purchase_category IS NULL;

-- V6. Fan-out safety check -- confirm the tiebreak CTE actually
-- resolved every multi-category first-order case (no duplicate
-- customer_unique_id should have survived into the final table)
SELECT customer_unique_id, COUNT(*) AS n
FROM `olist-analytics-500708.olist_serving.dim_customer`
GROUP BY customer_unique_id
HAVING COUNT(*) > 1;
-- Expected: 0 rows returned

-- V7. Confirm the tie-break rule actually reflects price, not just
-- alphabetical order by coincidence -- spot-check customers whose
-- earliest order had multiple distinct categories
WITH multi_category_first_orders AS (
  SELECT eo.customer_unique_id, eo.order_id
  FROM (
    SELECT customer_unique_id, order_id,
           ROW_NUMBER() OVER (PARTITION BY customer_unique_id ORDER BY order_purchase_timestamp ASC) AS rk
    FROM `olist-analytics-500708.olist_clean.orders` o
    JOIN `olist-analytics-500708.olist_clean.customers` c ON o.customer_id = c.customer_id
  ) eo
  WHERE eo.rk = 1
)
SELECT
  m.customer_unique_id,
  oi.price,
  p.product_category_name,
  gc.first_purchase_category AS resolved_category
FROM multi_category_first_orders m
JOIN `olist-analytics-500708.olist_clean.order_items` oi ON m.order_id = oi.order_id
JOIN `olist-analytics-500708.olist_clean.products` p ON oi.product_id = p.product_id
JOIN `olist-analytics-500708.olist_serving.dim_customer` gc ON m.customer_unique_id = gc.customer_unique_id
WHERE m.customer_unique_id IN (
  SELECT customer_unique_id FROM multi_category_first_orders m2
  JOIN `olist-analytics-500708.olist_clean.order_items` oi2 ON m2.order_id = oi2.order_id
  JOIN `olist-analytics-500708.olist_clean.products` p2 ON oi2.product_id = p2.product_id
  GROUP BY customer_unique_id
  HAVING COUNT(DISTINCT p2.product_category_name) > 1
)
ORDER BY m.customer_unique_id, oi.price DESC
LIMIT 30;
-- Manually verify: for each customer_unique_id, resolved_category
-- should match the category of the row with the highest price.


-- Rebuild dim_customer with both fixes applied, then re-run the exact
-- same discrepancy query that found this bug, to confirm 0 rows now.
-- (Same query as before -- included here for direct re-use.)

-- Fix the validation query itself with the same deterministic tiebreak,
-- so it's comparing apples to apples against the corrected dim_customer logic.
WITH customer_first_orders AS (
  SELECT
    c.customer_unique_id,
    o.order_id,
    ROW_NUMBER() OVER (
      PARTITION BY c.customer_unique_id
      ORDER BY o.order_purchase_timestamp ASC, o.order_id ASC  -- fix applied here too
    ) AS rk
  FROM `olist-analytics-500708.olist_clean.customers` c
  JOIN `olist-analytics-500708.olist_clean.orders` o
    ON c.customer_id = o.customer_id
),
first_orders_only AS (
  SELECT customer_unique_id, order_id FROM customer_first_orders WHERE rk = 1
),
expected_null_customers AS (
  SELECT fo.customer_unique_id
  FROM first_orders_only fo
  LEFT JOIN `olist-analytics-500708.olist_clean.order_items` oi
    ON fo.order_id = oi.order_id
  WHERE oi.order_id IS NULL
),
actual_null_customers AS (
  SELECT customer_unique_id
  FROM `olist-analytics-500708.olist_serving.dim_customer`
  WHERE first_purchase_category IS NULL
)
SELECT 'expected_null_but_not_actual' AS discrepancy_type, customer_unique_id
FROM expected_null_customers
WHERE customer_unique_id NOT IN (SELECT customer_unique_id FROM actual_null_customers)
UNION ALL
SELECT 'actual_null_but_not_expected', customer_unique_id
FROM actual_null_customers
WHERE customer_unique_id NOT IN (SELECT customer_unique_id FROM expected_null_customers);
-- Expected now: 0 rows