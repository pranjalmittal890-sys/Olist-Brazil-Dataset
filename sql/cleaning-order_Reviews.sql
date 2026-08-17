-- =====================================================================
-- CLEAN LAYER: order_reviews
-- Source: olist_raw.order_reviews ONLY (single-table dependency).
-- Purpose: Row-level standardization and flagging derived purely from
--          columns native to this table. No cross-table joins.
--          No fabrication of missing values. No row removal.
-- Note:    Null comment title/message are confirmed legitimate (optional
--          free-text fields) -- NOT converted to placeholder values, as
--          that would fabricate meaning where none exists. Multi-review
--          orders are confirmed genuine (not duplicates) and left as-is.
-- =====================================================================

CREATE OR REPLACE TABLE `olist-analytics-500708.olist_clean.order_reviews` AS

WITH standardized AS (

  SELECT
    -- Primary key. Defensive TRIM, consistent with ID handling
    -- elsewhere in the project.
    TRIM(review_id) AS review_id,
    TRIM(order_id)  AS order_id,

    -- review_score: left as-is. Profiling confirmed strict 1-5 domain,
    -- 0 nulls -- nothing to correct.
    review_score,

    -- Comment fields: TRIM applied ONLY where the value is not null,
    -- to normalize incidental whitespace without altering nullness.
    -- Profiling confirmed high null rates here are legitimate (optional
    -- fields) -- nulls are preserved exactly as-is, not replaced with
    -- a placeholder, since a placeholder would fabricate the appearance
    -- of content where the customer provided none.
    CASE WHEN review_comment_title IS NOT NULL
         THEN TRIM(review_comment_title) END AS review_comment_title,
    CASE WHEN review_comment_message IS NOT NULL
         THEN TRIM(review_comment_message) END AS review_comment_message,

    -- Explicit timestamp casts. Profiling confirmed clean parsing and
    -- 0 ordering violations -- type-safety formality only.
    CAST(review_creation_date AS TIMESTAMP)       AS review_creation_date,
    CAST(review_answer_timestamp AS TIMESTAMP)    AS review_answer_timestamp

  FROM `olist-analytics-500708.olist_raw.order_reviews`

)

SELECT * FROM standardized;

-- V1. Row count comparison
SELECT
  (SELECT COUNT(*) FROM `olist-analytics-500708.olist_raw.order_reviews`)   AS raw_row_count,
  (SELECT COUNT(*) FROM `olist-analytics-500708.olist_clean.order_reviews`) AS clean_row_count;
-- Expected: equal values

-- V2. Primary key uniqueness -- review_id
SELECT COUNT(*) AS total_rows, COUNT(DISTINCT review_id) AS distinct_review_ids
FROM `olist-analytics-500708.olist_clean.order_reviews`;
-- Expected: equal values

-- V3. Null profile -- review_score must remain 0; comment fields
-- null rate must match raw exactly (no imputation performed)
SELECT
  COUNTIF(review_score IS NULL)           AS null_score,          -- expect 0
  COUNTIF(review_comment_title IS NULL)   AS null_title,
  COUNTIF(review_comment_message IS NULL) AS null_message
FROM `olist-analytics-500708.olist_clean.order_reviews`;
-- Compare null_title / null_message directly against raw baseline --
-- must match exactly

-- V4. Domain validation -- review_score strictly 1-5
SELECT MIN(review_score) AS min_score, MAX(review_score) AS max_score
FROM `olist-analytics-500708.olist_clean.order_reviews`;
-- Expected: 1 and 5

-- V5. Timestamp ordering -- still 0 violations after cleaning
SELECT COUNTIF(review_answer_timestamp < review_creation_date) AS answered_before_created
FROM `olist-analytics-500708.olist_clean.order_reviews`;
-- Expected: 0

-- V6. Multi-review orders -- count unchanged from profiling baseline
SELECT reviews_per_order, COUNT(*) AS num_orders
FROM (
  SELECT order_id, COUNT(*) AS reviews_per_order
  FROM `olist-analytics-500708.olist_clean.order_reviews`
  GROUP BY order_id
)
GROUP BY reviews_per_order
ORDER BY reviews_per_order;
-- Expected: matches raw profiling distribution exactly

-- V7. Standardization check -- no leading/trailing whitespace on
-- non-null comment fields
SELECT COUNT(*) AS unstandardized_rows
FROM `olist-analytics-500708.olist_clean.order_reviews`
WHERE (review_comment_title IS NOT NULL AND review_comment_title != TRIM(review_comment_title))
   OR (review_comment_message IS NOT NULL AND review_comment_message != TRIM(review_comment_message));
-- Expected: 0

-- V8. Referential integrity -- order_reviews -> clean orders
SELECT COUNT(*) AS orphan_reviews_missing_order
FROM `olist-analytics-500708.olist_clean.order_reviews` r
LEFT JOIN `olist-analytics-500708.olist_clean.orders` o
  ON r.order_id = o.order_id
WHERE o.order_id IS NULL;
-- Expected: 0