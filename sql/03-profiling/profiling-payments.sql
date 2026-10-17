SELECT count(*) as row_cnt, 
count(distinct order_id) as order_cnt,
round(avg(payment_value),2) as avg_payment_value,
round(COUNT(*) / COUNT(DISTINCT order_id),2) as avg_payment_per_order
FROM `olist-analytics-500708.olist_raw.order_payments`

-- order_id and payment sequential uniqueness
select order_id, payment_sequential, count(*)
FROM `olist-analytics-500708.olist_raw.order_payments`
group by 1,2
having count(*)>1

select payment_per_order, count(*) as n
from (
  select order_id, count(*) as payment_per_order
  from `olist-analytics-500708.olist_raw.order_payments`
  group by order_id
)
group by payment_per_order
order by 1

-- 4.2 payment_type frequency
select payment_type, count(*) as cnt,
round(count(*)/sum(count(*)) over() * 100,2) as pcnt
FROM `olist-analytics-500708.olist_raw.order_payments`
group by payment_type
order by pcnt desc

-- 4.3 payment_installments range + distribution
select min(payment_installments) as min_pymt,
max(payment_installments) as max_pymt,
approx_quantiles(payment_installments,4) as quartiles
FROM `olist-analytics-500708.olist_raw.order_payments`

-- 4.4 payment_value range + quartiles
SELECT
  MIN(payment_value) AS min_val, MAX(payment_value) AS max_val,
  ROUND(AVG(payment_value), 2) AS avg_val,
  APPROX_QUANTILES(payment_value, 4) AS quartiles,
  COUNTIF(payment_value < 0) AS non_positive_count
FROM `olist-analytics-500708.olist_raw.order_payments`

-- orders with payment value<=0
select *
from `olist-analytics-500708.olist_raw.order_payments`
where payment_value<=0

-- NULL values count
select
countif(order_id is null) as order_id_null_cnt,
countif(payment_sequential is null) as payment_sequential_null_cnt,
countif(payment_type is null) as payment_type_null_cnt,
countif(payment_installments is null) as payment_installments_null_cnt,
countif(payment_value is null) as payment_value
from `olist-analytics-500708.olist_raw.order_payments`

-- Payment Sequential Validation
SELECT
order_id,
MAX(payment_sequential) AS max_seq,
COUNT(*) AS payment_rows
FROM `olist-analytics-500708.olist_raw.order_payments`
GROUP BY order_id
HAVING MAX(payment_sequential) != COUNT(*);

-- installment validation
SELECT
payment_type,
payment_installments,
COUNT(*) AS n
FROM `olist-analytics-500708.olist_raw.order_payments`
WHERE payment_installments = 0
GROUP BY 1,2;

select *
FROM `olist-analytics-500708.olist_raw.order_payments`
WHERE payment_installments = 0

SELECT *
FROM `olist-analytics-500708.olist_raw.orders`
WHERE order_id NOT IN (
SELECT DISTINCT order_id
FROM `olist-analytics-500708.olist_raw.order_payments`
);

SELECT
    order_id,
    ARRAY_AGG(payment_sequential ORDER BY payment_sequential) AS sequences,
    -- COUNT(*) AS payment_rows,
    ARRAY_AGG(payment_type ORDER BY payment_sequential) AS payment_types,
    -- MAX(payment_sequential) AS max_seq
    array_agg(payment_value order by payment_sequential) as payment_values
FROM `olist-analytics-500708.olist_raw.order_payments`
GROUP BY order_id
HAVING COUNT(*) != MAX(payment_sequential)
LIMIT 20;

-- Orders where COUNT(*) != MAX(payment_sequential)
WITH payment_totals AS (
    SELECT
        order_id,
        SUM(payment_value) AS total_payment
    FROM `olist-analytics-500708.olist_raw.order_payments`
    GROUP BY order_id
),

item_totals AS (
    SELECT
        order_id,
        SUM(price + freight_value) AS total_order_value
    FROM `olist-analytics-500708.olist_raw.order_items`
    GROUP BY order_id
)

SELECT
    COUNT(*) AS orders_compared,
    COUNTIF(
        ROUND(total_payment, 2) = ROUND(total_order_value, 2)
    ) AS matching_orders,
    COUNTIF(
        ROUND(total_payment, 2) != ROUND(total_order_value, 2)
    ) AS mismatching_orders
FROM payment_totals p
JOIN item_totals i
USING(order_id);

SELECT
  order_id,
  COUNT(*) AS payment_rows,
  SUM(payment_value) AS total_paid,
  COUNT(DISTINCT payment_type) AS distinct_payment_types
FROM `olist-analytics-500708.olist_raw.order_payments`
GROUP BY order_id
HAVING COUNT(DISTINCT payment_type) > 1
ORDER BY payment_rows DESC
LIMIT 50;

SELECT
    order_id,
    payment_sequential,
    payment_type,
    payment_installments,
    payment_value
FROM `olist-analytics-500708.olist_raw.order_payments`
WHERE order_id IN (
    SELECT order_id
    FROM `olist-analytics-500708.olist_raw.order_payments`
    GROUP BY order_id
    HAVING COUNT(*) != MAX(payment_sequential)
)
ORDER BY order_id, payment_sequential;

SELECT
    payment_type,
    payment_sequential,
    COUNT(*) AS n,
    COUNT(DISTINCT order_id) AS orders,
    AVG(payment_installments) AS avg_installments
FROM `olist-analytics-500708.olist_raw.order_payments`
WHERE order_id IN (
    SELECT order_id
    FROM `olist-analytics-500708.olist_raw.order_payments`
    GROUP BY order_id
    HAVING COUNT(*) != MAX(payment_sequential)
)
GROUP BY payment_type, payment_sequential
ORDER BY payment_type, payment_sequential;

SELECT *
FROM `olist-analytics-500708.olist_raw.orders`
WHERE order_id NOT IN (
    SELECT DISTINCT order_id
    FROM `olist-analytics-500708.olist_raw.order_payments`
);

select *
FROM `olist-analytics-500708.olist_raw.orders` o
LEFT JOIN `olist-analytics-500708.olist_raw.order_items` oi ON o.order_id = oi.order_id
WHERE o.order_id='bfbd0f9bdef84302105ad712db648a6c'

select *
FROM `olist-analytics-500708.olist_raw.orders` o
LEFT JOIN `olist-analytics-500708.olist_raw.order_items` oi ON o.order_id = oi.order_id
WHERE o.order_id= 'c8c528189310eaa44a745b8d9d26908b'

select *
FROM `olist-analytics-500708.olist_raw.orders` o
LEFT JOIN `olist-analytics-500708.olist_raw.order_items` oi ON o.order_id = oi.order_id
where o.order_id in (
    select order_id
from `olist-analytics-500708.olist_raw.order_payments`
where payment_value<=0
)

