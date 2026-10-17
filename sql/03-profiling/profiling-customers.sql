-- 2.1 Row count + the critical cardinality check: customer_id vs customer_unique_id
SELECT
  COUNT(*)                              AS row_count,
  COUNT(DISTINCT customer_id)           AS uniq_customer_id,
  COUNT(DISTINCT customer_unique_id)    AS uniq_person,
  ROUND(COUNT(DISTINCT customer_id) / COUNT(DISTINCT customer_unique_id), 3) AS orders_per_person_ratio
FROM `olist-analytics-500708.olist_raw.customers`

-- 2.2 Null profile
SELECT
  COUNTIF(customer_id IS NULL)                AS null_customer_id,
  COUNTIF(customer_unique_id IS NULL)         AS null_unique_id,
  COUNTIF(customer_zip_code_prefix IS NULL)   AS null_zip,
  COUNTIF(customer_city IS NULL)              AS null_city,
  COUNTIF(customer_state IS NULL)              AS null_state
FROM `olist-analytics-500708.olist_raw.customers`

-- 2.3 State distribution (low-cardinality dimension check)
select customer_state,
count(*) as n,
ROUND(COUNT(*) / SUM(COUNT(*)) OVER () * 100, 2) AS pct
FROM `olist-analytics-500708.olist_raw.customers`
GROUP BY customer_state
ORDER BY n DESC;

-- 2.4 Repeat-purchase distribution (how many orders per unique person)
SELECT orders_per_person, COUNT(*) AS num_people,
round(count(*)/sum(count(*)) over()*100,2) as pcnt
FROM (
  SELECT customer_unique_id, COUNT(*) AS orders_per_person
  FROM `olist-analytics-500708.olist_raw.customers`
  GROUP BY customer_unique_id
)
GROUP BY orders_per_person
ORDER BY orders_per_person;

-- total states and their abbreviates
SELECT
COUNT(DISTINCT customer_state) AS total_states,
STRING_AGG(DISTINCT customer_state ORDER BY customer_state) AS states
FROM `olist-analytics-500708.olist_raw.customers`;

-- zipcode values range
SELECT
MIN(customer_zip_code_prefix) AS min_zip,
MAX(customer_zip_code_prefix) AS max_zip
FROM `olist-analytics-500708.olist_raw.customers`;

SELECT
  COUNTIF(customer_zip_code_prefix < 0) AS negative_zip,
  COUNTIF(customer_zip_code_prefix > 99999) AS above_5_digits,
  COUNT(DISTINCT customer_zip_code_prefix) AS unique_zip_prefixes
FROM `olist-analytics-500708.olist_raw.customers`;

-- multiple states and city for unique customers
SELECT
customer_unique_id,
COUNT(DISTINCT customer_city) AS cities,
COUNT(DISTINCT customer_state) AS states
FROM `olist-analytics-500708.olist_raw.customers`
GROUP BY customer_unique_id
HAVING COUNT(DISTINCT customer_city) > 1
   OR COUNT(DISTINCT customer_state) > 1;

-- What percentage of orders came from repeat customers?
select 
count(*) as total_orders,
countif(orders_per_person>1) as repeat_customer_orders,
round(countif(orders_per_person>1)/count(*)*100,2) as pct_orders_from_repeat_customer
from (
  SELECT customer_unique_id, COUNT(*) AS orders_per_person
  FROM `olist-analytics-500708.olist_raw.customers`
  GROUP BY customer_unique_id
)

--Duplicate zip-city mapping
SELECT
customer_zip_code_prefix,
COUNT(DISTINCT customer_city)
FROM `olist-analytics-500708.olist_raw.customers`
GROUP BY customer_zip_code_prefix
HAVING COUNT(DISTINCT customer_city)>1;

SELECT
customer_zip_code_prefix,
ARRAY_AGG(DISTINCT customer_city ORDER BY customer_city) AS cities,
-- COUNT(*) AS sellers
ARRAY_AGG(DISTINCT customer_state ORDER BY customer_state) AS states,
FROM `olist-analytics-500708.olist_raw.customers`
GROUP BY customer_zip_code_prefix
HAVING COUNT(DISTINCT customer_city) > 1;