-- 1.1 Row count, key uniqueness, null profile
SELECT
  COUNT(*)                                                  AS row_count,
  COUNT(DISTINCT order_id)                                  AS distinct_order_id,
  COUNTIF(order_id IS NULL)                                 AS null_order_id,
  COUNTIF(customer_id IS NULL)                              AS null_customer_id,
  COUNTIF(order_status IS NULL)                             AS null_status,
  COUNTIF(order_purchase_timestamp IS NULL)                 AS null_purchase_ts,
  COUNTIF(order_approved_at IS NULL)                        AS null_approved_at,
  COUNTIF(order_delivered_carrier_date IS NULL)             AS null_delivered_carrier,
  COUNTIF(order_delivered_customer_date IS NULL)            AS null_delivered_customer,
  COUNTIF(order_estimated_delivery_date IS NULL)             AS null_estimated_delivery
FROM `olist-analytics-500708.olist_raw.orders`

select order_status, count(*) 
FROM `olist-analytics-500708.olist_raw.orders`
where order_approved_at is null 
group by order_status

select order_status, count(*) as n
FROM `olist-analytics-500708.olist_raw.orders`
where order_delivered_carrier_date IS NULL
group by order_status

select order_status, count(*) as n
FROM `olist-analytics-500708.olist_raw.orders`
where order_delivered_customer_date IS NULL
group by order_status

select *
FROM `olist-analytics-500708.olist_raw.orders`
where (order_delivered_customer_date IS NULL
or order_delivered_carrier_date is null
or order_approved_at is null)
and order_status = 'delivered'

-- 1.2 Null rate as % (easier to compare across columns)
SELECT
  ROUND(COUNTIF(order_approved_at IS NULL) / COUNT(*) * 100, 2)            AS pct_null_approved,
  ROUND(COUNTIF(order_delivered_carrier_date IS NULL) / COUNT(*) * 100, 2) AS pct_null_carrier,
  ROUND(COUNTIF(order_delivered_customer_date IS NULL) / COUNT(*) * 100, 2) AS pct_null_delivered
FROM `olist-analytics-500708.olist_raw.orders`

-- 1.3 order_status frequency distribution
select order_status, count(*) as order_status_count,
round(count(*)/sum(count(*)) over()*100,2) as pct
from `olist-analytics-500708.olist_raw.orders`
group by order_status
order by order_status_count desc

-- 1.4 Cross-check: is null delivered_customer_date concentrated in non-'delivered' status?
-- (tests the MNAR/structural-missing hypothesis
select order_status,
COUNT(*) AS n,
countif(order_delivered_customer_date IS NULL) AS null_delivered,
ROUND(COUNTIF(order_delivered_customer_date IS NULL) / COUNT(*) * 100, 2) AS pct_null
from `olist-analytics-500708.olist_raw.orders`
group by order_status
order by n desc

select *
from `olist-analytics-500708.olist_raw.orders`
where order_status = 'canceled' and order_delivered_customer_date IS not NULL

select *
from `olist-analytics-500708.olist_raw.orders`
where order_status = 'delivered' and order_delivered_customer_date IS NULL

-- Date range (purchase_timestamp)
select min(order_purchase_timestamp), max(order_purchase_timestamp),
countif(order_purchase_timestamp is null)
from `olist-analytics-500708.olist_raw.orders`

select min(order_delivered_customer_date), max(order_delivered_customer_date)
from `olist-analytics-500708.olist_raw.orders`

-- 1.6 Logical consistency: any timestamps out of order?
select
countif(order_approved_at < order_purchase_timestamp) AS approved_before_purchase,
COUNTIF(order_delivered_customer_date < order_purchase_timestamp) AS delivered_before_purchase,
countif(order_delivered_customer_date < order_delivered_carrier_date) AS delivered_before_carrier,
countif(order_delivered_carrier_date < order_approved_at) AS delivered_before_approved
from `olist-analytics-500708.olist_raw.orders`

select *
from `olist-analytics-500708.olist_raw.orders`
where order_delivered_customer_date < order_delivered_carrier_date

select *
from `olist-analytics-500708.olist_raw.orders`
where order_delivered_carrier_date < order_approved_at

SELECT
EXTRACT(YEAR FROM order_purchase_timestamp) yr,
EXTRACT(MONTH FROM order_purchase_timestamp) mon,
COUNT(*) cnt
FROM `olist-analytics-500708.olist_raw.orders`
WHERE order_delivered_customer_date < order_delivered_carrier_date
GROUP BY 1,2
ORDER BY 1,2;

SELECT
  order_id, order_status,order_purchase_timestamp, order_approved_at,order_delivered_carrier_date,
  order_delivered_customer_date,
  TIMESTAMP_DIFF(order_delivered_customer_date, order_delivered_carrier_date,HOUR
  ) AS delivery_before_carrier_hours
FROM `olist-analytics-500708.olist_raw.orders`
WHERE order_delivered_customer_date < order_delivered_carrier_date
ORDER BY delivery_before_carrier_hours;

SELECT
  EXTRACT(YEAR FROM order_purchase_timestamp) AS yr,
  EXTRACT(MONTH FROM order_purchase_timestamp) AS mon,
  COUNT(*) AS cnt
FROM `olist-analytics-500708.olist_raw.orders`
WHERE order_delivered_carrier_date < order_approved_at
GROUP BY 1, 2
ORDER BY 1, 2;

-- How many hours/days apart?
select 
TIMESTAMP_DIFF(order_approved_at,order_delivered_carrier_date,HOUR) as hour_diff,
count(*) as n, count(*)/sum(count(*)) over()*100 as pct
FROM `olist-analytics-500708.olist_raw.orders`
WHERE order_delivered_carrier_date < order_approved_at
group by 1
order by 1

-- 1.7 Monthly volume —
select
format_timestamp('%Y-%m', order_purchase_timestamp) as year_month,
count(*) as n
from `olist-analytics-500708.olist_raw.orders`
GROUP BY year_month
ORDER BY year_month;

--Unparseable timestamps
SELECT
  MIN(SAFE_CAST(order_purchase_timestamp AS TIMESTAMP)) AS min_purchase_ts,
  MAX(SAFE_CAST(order_purchase_timestamp AS TIMESTAMP)) AS max_purchase_ts,
  COUNTIF(SAFE_CAST(order_purchase_timestamp AS TIMESTAMP) IS NULL
  AND order_purchase_timestamp IS NOT NULL)  AS unparseable_purchase_ts
from `olist-analytics-500708.olist_raw.orders`

-- approval time distribution
SELECT
  COUNT(*) AS orders,
  MIN(TIMESTAMP_DIFF(order_approved_at, order_purchase_timestamp, HOUR)) AS min_hours,
  APPROX_QUANTILES(
      TIMESTAMP_DIFF(order_approved_at, order_purchase_timestamp, HOUR), 100
  )[OFFSET(50)] AS median_hours,
  APPROX_QUANTILES(
      TIMESTAMP_DIFF(order_approved_at, order_purchase_timestamp, HOUR), 100
  )[OFFSET(95)] AS p95_hours,
  approx_quantiles(
    TIMESTAMP_DIFF(order_approved_at, order_purchase_timestamp, HOUR), 100
  )[OFFSET(99)] AS p99_hours,
  MAX(TIMESTAMP_DIFF(order_approved_at, order_purchase_timestamp, HOUR)) AS max_hours
FROM `olist-analytics-500708.olist_raw.orders`
WHERE order_approved_at IS NOT NULL;

-- status of long hours orders
select *
FROM `olist-analytics-500708.olist_raw.orders`
WHERE order_approved_at IS NOT NULL and TIMESTAMP_DIFF(order_approved_at, order_purchase_timestamp, HOUR) >= 1000

-- shipping duration
SELECT
  COUNT(*) AS orders,
  MIN(TIMESTAMP_DIFF(order_delivered_carrier_date,
                     order_approved_at,
                     HOUR)) AS min_hours,
  APPROX_QUANTILES(
      TIMESTAMP_DIFF(order_delivered_carrier_date,
                     order_approved_at,
                     HOUR),100)[OFFSET(50)] AS median_hours,
  APPROX_QUANTILES(
      TIMESTAMP_DIFF(order_delivered_carrier_date,
                     order_approved_at,
                     HOUR),100)[OFFSET(95)] AS p95_hours,
  APPROX_QUANTILES(
      TIMESTAMP_DIFF(order_delivered_carrier_date,
                     order_approved_at,
                     HOUR),100)[OFFSET(99)] AS p99_hours,
  MAX(TIMESTAMP_DIFF(order_delivered_carrier_date,
                     order_approved_at,
                     HOUR)) AS max_hours
FROM `olist-analytics-500708.olist_raw.orders`
WHERE order_approved_at IS NOT NULL
AND order_delivered_carrier_date IS NOT NULL;

-- max hr order status
select *
FROM `olist-analytics-500708.olist_raw.orders`
WHERE order_approved_at IS NOT NULL and TIMESTAMP_DIFF(order_delivered_carrier_date,order_approved_at,HOUR) =3018

select *
FROM `olist-analytics-500708.olist_raw.orders`
WHERE order_approved_at IS NOT NULL and TIMESTAMP_DIFF(order_delivered_carrier_date,order_approved_at,HOUR) = -4109

select *
FROM `olist-analytics-500708.olist_raw.orders`
WHERE order_approved_at IS NOT NULL and TIMESTAMP_DIFF(order_delivered_carrier_date,order_approved_at,HOUR) < 0

-- delivery duration
SELECT
  COUNT(*) AS orders,
  MIN(TIMESTAMP_DIFF(order_delivered_customer_date,
                     order_delivered_carrier_date,
                     DAY)) AS min_days,
  APPROX_QUANTILES(
      TIMESTAMP_DIFF(order_delivered_customer_date,
                     order_delivered_carrier_date,
                     DAY),100)[OFFSET(50)] AS median_days,
  APPROX_QUANTILES(
      TIMESTAMP_DIFF(order_delivered_customer_date,
                     order_delivered_carrier_date,
                     DAY),100)[OFFSET(95)] AS p95_days,
  MAX(TIMESTAMP_DIFF(order_delivered_customer_date,
                     order_delivered_carrier_date,
                     DAY)) AS max_days
FROM `olist-analytics-500708.olist_raw.orders`
WHERE order_delivered_customer_date IS NOT NULL
AND order_delivered_carrier_date IS NOT NULL;

-- distribution of orders except delivered ones
select
extract(year from order_purchase_timestamp) as yr,
extract(month from order_purchase_timestamp) as mon,
order_status,
count(*) as n
from `olist-analytics-500708.olist_raw.orders`
where order_status!='delivered'
group by 1,2,3
order by 1,2,3

