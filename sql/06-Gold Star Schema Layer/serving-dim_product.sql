-- =====================================================================
-- serving LAYER: dim_product
-- Source: olist_clean.products, olist_clean.category_translation
--          (Clean Layer only)
-- Grain: one row per product_id.
-- Approved columns only: product_key, product_id, category_name,
--          category_name_english. No physical/text-length attributes --
--          rejected during architecture review, not revisited here.
-- =====================================================================

CREATE OR REPLACE TABLE `olist-analytics-500708.olist_serving.dim_product` AS

SELECT
  -- Surrogate key, deterministic on natural key ordering for
  -- reproducibility across rebuilds.
  ROW_NUMBER() OVER (ORDER BY p.product_id) AS product_key,

  p.product_id,

  -- Direct copy. Already TRIM/LOWER-standardized and NULL-imputed to
  -- 'unknown' in the Silver layer -- no further transformation needed
  -- here.
  p.product_category_name AS category_name,

  -- COALESCE fallback: use the English translation where a mapping
  -- exists in category_translation; fall back to the Portuguese name
  -- otherwise. This is the deferred decision from the Silver-layer
  -- category_translation cleaning sign-off (RI-10: 2 categories with
  -- no English translation) -- landing here as planned, not a new
  -- fabrication. The 'unknown' placeholder (from Silver's null-category
  -- imputation) will also correctly fall through this COALESCE with no
  -- translation match, displaying as 'unknown' rather than blank.
  COALESCE(ct.category_name_english, p.product_category_name) AS category_name_english

FROM `olist-analytics-500708.olist_clean.products` p
LEFT JOIN `olist-analytics-500708.olist_clean.category_translation` ct
  ON p.product_category_name = ct.category_name_portuguese;

-- V1. Row count -- must equal distinct product_id count in Silver
SELECT
  (SELECT COUNT(DISTINCT product_id) FROM `olist-analytics-500708.olist_clean.products`) AS silver_count,
  (SELECT COUNT(*) FROM `olist-analytics-500708.olist_serving.dim_product`) AS serving_count;
-- Expected: equal

-- V2. Primary key validation
SELECT COUNT(*) AS total_rows, COUNT(DISTINCT product_key) AS distinct_keys,
       COUNT(DISTINCT product_id) AS distinct_natural_keys
FROM `olist-analytics-500708.olist_serving.dim_product`;
-- Expected: all three equal

-- V3. Null checks -- category_name should never be null (Silver already
-- imputed to 'unknown'); category_name_english should ALSO never be
-- null, since COALESCE guarantees a fallback value always exists
SELECT
  COUNTIF(category_name IS NULL)          AS null_category,
  COUNTIF(category_name_english IS NULL)  AS null_category_english
FROM `olist-analytics-500708.olist_serving.dim_product`;
-- Expected: both 0. If category_name_english is ever non-zero, the
-- COALESCE fallback logic itself has a bug -- this should be
-- structurally impossible given the transformation.

-- V4. Confirm the COALESCE fallback actually fired for the 2 known
-- untranslated categories from profiling
SELECT product_id, category_name, category_name_english
FROM `olist-analytics-500708.olist_serving.dim_product`
WHERE category_name IN ('pc_gamer', 'portateis_cozinha_e_preparadores_de_alimentos');
-- Expected: category_name_english equals category_name exactly for
-- these rows (Portuguese used as fallback, confirming no translation
-- match was found, as expected)

-- V5. Confirm 'unknown' placeholder rows fall back correctly too
SELECT COUNT(*) AS unknown_rows,
       COUNTIF(category_name_english = 'unknown') AS unknown_correctly_coalesced
FROM `olist-analytics-500708.olist_serving.dim_product`
WHERE category_name = 'unknown';
-- Expected: unknown_rows = unknown_correctly_coalesced (should match
-- the 610-row count from Silver's category imputation)

-- V6. Confirm translation actually applied where a real mapping exists
-- (spot check against a known, well-translated category)
SELECT DISTINCT category_name, category_name_english
FROM `olist-analytics-500708.olist_serving.dim_product`
WHERE category_name != category_name_english
LIMIT 10;
-- Expected: rows here show genuine Portuguese->English pairs, confirming
-- the JOIN is matching correctly, not just falling through to COALESCE
-- for everything

-- V7. Referential integrity -- fact table product_id values should
-- all resolve to a product_key here (run once fact table is built)
SELECT COUNT(*) AS orphan_fact_products
FROM `olist-analytics-500708.olist_clean.order_items` oi
LEFT JOIN `olist-analytics-500708.olist_serving.dim_product` dp
  ON oi.product_id = dp.product_id
WHERE dp.product_id IS NULL;
-- Expected: 0 (mirrors RI-3, already confirmed clean in Silver)

