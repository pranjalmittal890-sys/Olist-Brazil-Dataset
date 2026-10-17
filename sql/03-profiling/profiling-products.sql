select count(*) as cnt_row,
count(distinct product_id) as product_cnt
from `olist-analytics-500708.olist_raw.products`

SELECT
  COUNTIF(product_category_name IS NULL)   AS null_category,
  round(COUNTIF(product_category_name IS NULL)/count(*)*100,2) as null_category_pcnt,
  COUNTIF(product_weight_g IS NULL)        AS null_weight,
  COUNTIF(product_length_cm IS NULL)       AS null_length,
  COUNTIF(product_height_cm IS NULL)       AS null_height,
  COUNTIF(product_width_cm IS NULL)        AS null_width,
  COUNTIF(product_photos_qty IS NULL)      AS null_photos_qty
from `olist-analytics-500708.olist_raw.products`

-- identify rows with null metadata -
select *
from `olist-analytics-500708.olist_raw.products`
where product_weight_g is null
or product_length_cm is null
or product_height_cm is null
or product_width_cm is null

select approx_quantiles(product_weight_g,4) as wght,
round(avg(product_weight_g),2),
approx_quantiles(product_length_cm,4) as lngth,
round(avg(product_length_cm),2),
approx_quantiles(product_height_cm,4) as hgth,
round(avg(product_height_cm),2),
approx_quantiles(product_width_cm,4) as wdth,
round(avg(product_width_cm),2)
from `olist-analytics-500708.olist_raw.products`
where product_category_name='bebes'

-- category and qty same orders NULL?
select *
from `olist-analytics-500708.olist_raw.products`
where product_category_name is null
and product_photos_qty is null

-- null category products present in order items?
select distinct product_id
from `olist-analytics-500708.olist_raw.order_items`
where product_id in (
  select product_id from `olist-analytics-500708.olist_raw.products` where product_category_name is null)

-- 6.3 Category cardinality + top categories
SELECT
  COUNT(DISTINCT product_category_name) AS distinct_categories
  from `olist-analytics-500708.olist_raw.products`

-- 6.4 Weight/dimension range (sanity check for zero/negative/absurd values)
SELECT
  MIN(product_weight_g) AS min_weight, MAX(product_weight_g) AS max_weight,
  COUNTIF(product_weight_g = 0) AS zero_weight_count
from `olist-analytics-500708.olist_raw.products`

-- identify 4 weights = 0 rows
select *
from `olist-analytics-500708.olist_raw.products`
where product_weight_g=0

SELECT
  MIN(product_length_cm) AS min_length, MAX(product_length_cm) AS max_length,
  MIN(product_height_cm) AS min_height, MAX(product_height_cm) AS max_height,
  MIN(product_width_cm) AS min_width, MAX(product_width_cm) AS max_width
from `olist-analytics-500708.olist_raw.products`

select product_category_name, count(*) as cnt
from `olist-analytics-500708.olist_raw.products`
group by product_category_name
order by cnt desc limit 10

select MIN(product_description_lenght) AS min_length, 
MAX(product_description_lenght) AS max_length,
min(product_name_lenght) AS min_name_length, 
MAX(product_name_lenght) AS max_name_length,
min(product_photos_qty) as min_photos_qty, 
max(product_photos_qty) as max_photos_qty
from `olist-analytics-500708.olist_raw.products`


SELECT round(avg(product_weight_g),2) as mean,
APPROX_QUANTILES(product_weight_g,4) as quantile
FROM `olist-analytics-500708.olist_raw.products`
WHERE product_category_name='cama_mesa_banho'
AND product_weight_g>0;

SELECT
    COUNT(DISTINCT oi.product_id) AS null_category_products,
    COUNT(DISTINCT oi.order_id) AS affected_orders,
    COUNT(*) AS affected_order_items,
    ROUND(SUM(oi.price), 2) AS affected_revenue
FROM `olist-analytics-500708.olist_raw.order_items` oi
JOIN `olist-analytics-500708.olist_raw.products` p
    USING(product_id)
WHERE p.product_category_name IS NULL;

-- weight =0 present in order items?
SELECT
    p.product_id,
    COUNT(oi.order_id) AS order_items,
    ROUND(SUM(oi.price), 2) AS revenue
FROM `olist-analytics-500708.olist_raw.products` p
LEFT JOIN `olist-analytics-500708.olist_raw.order_items` oi
    USING(product_id)
WHERE p.product_weight_g = 0
GROUP BY p.product_id
ORDER BY revenue DESC;

-- weight/length/height/width all cols null present in order_items?
SELECT
    COUNT(*) AS order_items,
    COUNT(DISTINCT order_id) AS orders,
    ROUND(SUM(price), 2) AS revenue
FROM `olist-analytics-500708.olist_raw.order_items`
WHERE product_id in ('5eb564652db742ff8f28759cd8d2652a', '09ff539a621711667c43eba6a3bd8466')

-- NULL all columns product id present in order items?
SELECT
    COUNT(*) AS order_items,
    COUNT(DISTINCT order_id) AS orders,
    ROUND(SUM(price), 2) AS revenue
FROM `olist-analytics-500708.olist_raw.order_items`
WHERE product_id = '5eb564652db742ff8f28759cd8d2652a';