SELECT count(*) as row_count,
count(distinct seller_id) as seller_count,
count(distinct seller_city) as city,
count(distinct seller_state) as state,
count(distinct seller_zip_code_prefix) as zip
FROM `olist-analytics-500708.olist_raw.sellers`

-- NULL count
select COUNTIF(seller_zip_code_prefix IS NULL) AS null_zip,
  COUNTIF(seller_city IS NULL) AS null_city,
  COUNTIF(seller_state IS NULL) AS null_state
FROM `olist-analytics-500708.olist_raw.sellers`

-- state wise distribution of sellers
select seller_state, count(*) as n
FROM `olist-analytics-500708.olist_raw.sellers`
group by seller_state
order by n desc

-- zip code and state length
select max(seller_zip_code_prefix) as max_zip, 
min(seller_zip_code_prefix) as min_zip,
max(length(seller_state)) as state_len
FROM `olist-analytics-500708.olist_raw.sellers`

--Duplicate zip-city mapping
SELECT
seller_zip_code_prefix,
COUNT(DISTINCT seller_city)
FROM `olist-analytics-500708.olist_raw.sellers`
GROUP BY seller_zip_code_prefix
HAVING COUNT(DISTINCT seller_city)>1;

SELECT
seller_zip_code_prefix,
ARRAY_AGG(DISTINCT seller_city ORDER BY seller_city) AS cities,
-- COUNT(*) AS sellers
ARRAY_AGG(DISTINCT seller_state ORDER BY seller_state) AS states,
FROM `olist-analytics-500708.olist_raw.sellers`
GROUP BY seller_zip_code_prefix
HAVING COUNT(DISTINCT seller_city) > 1;

SELECT
    seller_zip_code_prefix,
    seller_city,
    COUNT(*) AS sellers
FROM `olist-analytics-500708.olist_raw.sellers`
-- where seller_zip_code_prefix =22790
-- WHERE seller_city='lages - sc'
GROUP BY 1,2
ORDER BY sellers DESC;

--same city, multiple states
SELECT
seller_city,
COUNT(DISTINCT seller_state)
FROM `olist-analytics-500708.olist_raw.sellers`
GROUP BY seller_city
HAVING COUNT(DISTINCT seller_state)>1;

SELECT
seller_city,
ARRAY_AGG(DISTINCT seller_state ORDER BY seller_state) AS states,
COUNT(*) AS sellers
FROM `olist-analytics-500708.olist_raw.sellers`
GROUP BY seller_city
HAVING COUNT(DISTINCT seller_state) > 1;

select distinct lower(trim(seller_city)) as seller_city
FROM `olist-analytics-500708.olist_raw.sellers`
order by seller_city

--city frequency
SELECT
seller_city,
COUNT(*) AS sellers
FROM `olist-analytics-500708.olist_raw.sellers`
GROUP BY seller_city
ORDER BY sellers DESC;

select *
from `olist-analytics-500708.olist_raw.order_items` oi join
`olist-analytics-500708.olist_raw.orders` o
on oi.order_id=o.order_id
where seller_id='ceb7b4fb9401cd378de7886317ad1b47'

select *
from `olist-analytics-500708.olist_raw.orders`
where order_id in (
  select order_id from `olist-analytics-500708.olist_raw.order_items` where seller_id='47efca563408aae19bb7206c2d969ea9')

SELECT
    COUNT(*) AS total_sellers,
    COUNTIF(oi.seller_id IS NOT NULL) AS sellers_with_orders,
    COUNTIF(oi.seller_id IS NULL) AS sellers_without_orders
FROM `olist-analytics-500708.olist_raw.sellers` s
LEFT JOIN (
    SELECT DISTINCT seller_id
    FROM `olist-analytics-500708.olist_raw.order_items`
) oi
USING (seller_id);