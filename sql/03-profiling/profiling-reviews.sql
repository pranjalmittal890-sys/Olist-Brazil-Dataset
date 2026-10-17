-- 5.1 Row count + grain check
SELECT
  COUNT(*) AS row_cnt,
  COUNT(DISTINCT review_id) AS distinct_reviews,
  COUNT(DISTINCT order_id) AS distinct_orders
FROM `olist-analytics-500708.olist_raw.order_reviews`;

-- review id and order id uniqueness
select review_id, order_id, count(*)
FROM `olist-analytics-500708.olist_raw.order_reviews`
group by 1,2
having count(*)>1

SELECT
    COUNT(*) AS duplicate_review_ids,
    COUNTIF(order_count = 1) AS same_order,
    COUNTIF(order_count > 1) AS multiple_orders
FROM (
    SELECT
        review_id,
        COUNT(*) AS row_count,
        COUNT(DISTINCT order_id) AS order_count
    FROM `olist-analytics-500708.olist_raw.order_reviews`
    GROUP BY review_id
    HAVING COUNT(*) > 1
);

-- 5.2 review_score distribution
SELECT review_score, COUNT(*) AS n,
       ROUND(COUNT(*) / SUM(COUNT(*)) OVER () * 100, 2) AS pct
FROM `olist-analytics-500708.olist_raw.order_reviews`
GROUP BY review_score
ORDER BY review_score;

-- 5.3 Null profile (comment text fields are often sparsely filled — expected)
SELECT
  COUNTIF(review_score IS NULL) AS null_score,
  COUNTIF(review_comment_title IS NULL) AS null_title,
  COUNTIF(review_comment_message IS NULL) AS null_message,
  ROUND(COUNTIF(review_comment_message IS NULL) / COUNT(*) * 100, 2) AS pct_null_message
FROM `olist-analytics-500708.olist_raw.order_reviews`;

-- distribution of review msgs based on review scores
select review_score, 
round(countif(review_comment_message is null)/sum(countif(review_comment_message is null)) over()*100,2) as n
FROM `olist-analytics-500708.olist_raw.order_reviews`
group by review_score
order by n desc

-- 5.4 Orders with more than one review (grain anomaly check)
SELECT reviews_per_order, COUNT(*) AS num_orders
FROM (
  SELECT order_id, COUNT(*) AS reviews_per_order
  FROM `olist-analytics-500708.olist_raw.order_reviews`
  GROUP BY order_id
)
GROUP BY reviews_per_order
ORDER BY reviews_per_order;

select countif(review_answer_timestamp is null),
countif(review_creation_date is null)
FROM `olist-analytics-500708.olist_raw.order_reviews`

select min(review_answer_timestamp) as min_ans,
max(review_answer_timestamp) as max_ans,
min(review_creation_date) as min_cre,
max(review_creation_date) as max_cre
FROM `olist-analytics-500708.olist_raw.order_reviews`

-- >1 reviews
SELECT
    order_id,
    review_id,
    review_score,
    review_creation_date,
    review_answer_timestamp,
    review_comment_message
FROM `olist-analytics-500708.olist_raw.order_reviews`
WHERE order_id IN (
    SELECT order_id
    FROM `olist-analytics-500708.olist_raw.order_reviews`
    GROUP BY order_id
    HAVING COUNT(*) > 1
)
ORDER BY order_id;

-- any date anomaly
SELECT
COUNTIF(review_answer_timestamp < review_creation_date) AS answered_before_created
FROM `olist-analytics-500708.olist_raw.order_reviews`;

-- range ofreview scores
SELECT
MIN(review_score),
MAX(review_score)
FROM `olist-analytics-500708.olist_raw.order_reviews`;

-- length of review message
SELECT
MIN(LENGTH(review_comment_message)) AS min_len,
APPROX_QUANTILES(LENGTH(review_comment_message),4) AS quartiles,
MAX(LENGTH(review_comment_message)) AS max_len
FROM `olist-analytics-500708.olist_raw.order_reviews`
WHERE review_comment_message IS NOT NULL;
