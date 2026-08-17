-- =====================================================================
-- CLEAN LAYER: products
-- Source: olist_raw.products ONLY (single-table dependency by design).
-- Purpose: Row-level standardization, one justified imputation (zero-
--          weight correction), and flagging. No cross-table joins
--          beyond a self-referential median calculation (still single-
--          source). No row removal.
-- Note:    RI-3 (0 orphans against order_items) and RI-10 (2 categories
--          with no English translation) are cross-table facts and
--          explicitly OUT OF SCOPE here -- documented separately.
-- =====================================================================

CREATE OR REPLACE TABLE `olist-analytics-500708.olist_clean.products` AS

WITH standardized AS (

  SELECT
    -- Primary key. Defensive TRIM, consistent with ID handling
    -- elsewhere in the project.
    TRIM(product_id) AS product_id,

    -- Standardize category defensively: TRIM + LOWER. Profiling found
    -- non-null values already clean -- zero-risk formality.
    LOWER(TRIM(product_category_name)) AS product_category_name_raw,

    -- Dimension fields left as-is numerically at this stage. Profiling
    -- confirmed no negative values; only the zero-weight case (handled
    -- separately below) required correction.
    product_weight_g,
    product_length_cm,
    product_height_cm,
    product_width_cm,

    -- Informational fields: profiling found no defect, no cleaning
    -- action justified. Passed through unchanged.
    product_name_lenght,
    product_description_lenght,
    product_photos_qty

  FROM `olist-analytics-500708.olist_raw.products`

),

-- Category-level median weight, computed from products with a valid
-- (non-null, non-zero) weight only. Powers the zero-weight imputation
-- below. This is a within-table aggregation (products against itself),
-- not a cross-table join -- stays in scope for this layer.
category_median_weight AS (
  SELECT
    product_category_name_raw,
    APPROX_QUANTILES(product_weight_g, 2)[OFFSET(1)] AS median_weight_g
  FROM standardized
  WHERE product_weight_g > 0
  GROUP BY product_category_name_raw
),

imputed AS (

  SELECT
    s.product_id,

    -- FLAG + IMPUTE: 610 null categories replaced with explicit
    -- 'unknown' label. Profiling finding: these products are confirmed
    -- revenue-valid (appear in real order_items rows) and must be
    -- retained. NULL is replaced with a defined placeholder so
    -- GROUP BY / category-level reporting doesn't silently drop these
    -- rows -- this is an explicit-absence convention, not a fabricated
    -- category guess.
    COALESCE(s.product_category_name_raw, 'unknown') AS product_category_name,

    -- IMPUTE: zero-weight products (4 rows) replaced with the median
    -- weight of their own category. Justified because zero weight is
    -- physically impossible for a shippable product -- objective
    -- evidence of an error, not a plausible legitimate value. Median
    -- chosen over mean due to confirmed right-skew in weight
    -- distributions. Products with a valid weight are passed through
    -- unchanged.
    CASE
      WHEN s.product_weight_g = 0
        THEN COALESCE(cmw.median_weight_g, s.product_weight_g)
      ELSE s.product_weight_g
    END AS product_weight_g,

    -- Dimensions other than weight: left completely unchanged. No
    -- physical-impossibility evidence found for these fields in
    -- profiling -- retained and documented if nulls exist, not imputed.
    s.product_length_cm,
    s.product_height_cm,
    s.product_width_cm,

    s.product_name_lenght,
    s.product_description_lenght,
    s.product_photos_qty,

    -- FLAG 1: this row's category was NULL in the source and has been
    -- replaced with 'unknown'. Makes the imputation traceable/reversible
    -- for anyone auditing the clean layer.
    (s.product_category_name_raw IS NULL)
        AS had_null_category,

    -- FLAG 2: this row's weight was 0 in the source and has been
    -- replaced with the category median. Same traceability purpose.
    (s.product_weight_g = 0)
        AS had_zero_weight_imputed

  FROM standardized s
  LEFT JOIN category_median_weight cmw
    ON s.product_category_name_raw = cmw.product_category_name_raw

)

SELECT * FROM imputed;

-- V1. Row count comparison
SELECT
  (SELECT COUNT(*) FROM `olist-analytics-500708.olist_raw.products`)   AS raw_row_count,
  (SELECT COUNT(*) FROM `olist-analytics-500708.olist_clean.products`) AS clean_row_count;
-- Expected: equal values

-- V2. Primary key uniqueness
SELECT COUNT(*) AS total_rows, COUNT(DISTINCT product_id) AS distinct_product_ids
FROM `olist-analytics-500708.olist_clean.products`;
-- Expected: equal values

-- V3. Category null handling -- confirm 0 raw NULLs remain, all
-- replaced with 'unknown', and count matches profiling baseline
SELECT
  COUNTIF(product_category_name IS NULL)        AS remaining_nulls,      -- expect 0
  COUNTIF(product_category_name = 'unknown')     AS unknown_count,       -- expect 610
  COUNTIF(had_null_category)                     AS flagged_count        -- expect 610
FROM `olist-analytics-500708.olist_clean.products`;

-- V4. Zero-weight imputation -- confirm 0 remain at zero, and exactly
-- 4 rows were imputed
SELECT
  COUNTIF(product_weight_g = 0)      AS remaining_zero_weight,  -- expect 0
  COUNTIF(had_zero_weight_imputed)   AS imputed_count            -- expect 4
FROM `olist-analytics-500708.olist_clean.products`;

-- V5. Spot-check the imputed values are sane (non-zero, non-null,
-- plausible relative to their category)
SELECT product_id, product_category_name, product_weight_g, had_zero_weight_imputed
FROM `olist-analytics-500708.olist_clean.products`
WHERE had_zero_weight_imputed = TRUE;
-- Manually confirm: product_weight_g > 0 for all 4 rows

-- V6. Domain validation -- no negative dimensions or weight anywhere
SELECT
  COUNTIF(product_weight_g < 0)   AS negative_weight,   -- expect 0
  COUNTIF(product_length_cm < 0)  AS negative_length,   -- expect 0
  COUNTIF(product_height_cm < 0)  AS negative_height,   -- expect 0
  COUNTIF(product_width_cm < 0)   AS negative_width      -- expect 0
FROM `olist-analytics-500708.olist_clean.products`;

-- V7. Standardization check -- category values are clean lowercase,
-- no whitespace, 'unknown' is the only synthetic value present
SELECT DISTINCT product_category_name
FROM `olist-analytics-500708.olist_clean.products`
ORDER BY product_category_name
LIMIT 20;

-- V8. Referential integrity -- order_items -> clean products
-- (re-run against the clean version now that it exists, superseding
-- the earlier raw-table check noted as a standing dependency)
SELECT COUNT(*) AS orphan_items_missing_product
FROM `olist-analytics-500708.olist_clean.order_items` oi
LEFT JOIN `olist-analytics-500708.olist_clean.products` p
  ON oi.product_id = p.product_id
WHERE p.product_id IS NULL;
-- Expected: 0