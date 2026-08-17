-- =====================================================================
-- CLEAN LAYER: category_translation
-- Source: olist_raw.category_translation ONLY (single-table dependency).
-- Purpose: Rename generic auto-detected column names for clarity,
--          apply defensive standardization. No cross-table joins.
--          No fabrication of missing translations. No row removal.
-- Note:    RI-10 (2 product categories with no translation row here)
--          is a cross-table fact, already documented at the products
--          cleaning stage -- not re-addressed here, since there is
--          nothing to fix WITHIN this table (the gap is an absence of
--          a row, not a defect in an existing row).
-- =====================================================================

CREATE OR REPLACE TABLE `olist-analytics-500708.olist_clean.category_translation` AS

SELECT
  -- Renamed from string_field_0 for clarity -- pure schema readability
  -- improvement, does not alter the underlying value. Defensive
  -- TRIM/LOWER applied for consistent joins to products.product_category_name.
  LOWER(TRIM(string_field_0)) AS category_name_portuguese,

  -- Renamed from string_field_1 for clarity, same reasoning.
  LOWER(TRIM(string_field_1)) AS category_name_english

FROM `olist-analytics-500708.olist_raw.category_translation`;

-- V1. Row count comparison
SELECT
  (SELECT COUNT(*) FROM `olist-analytics-500708.olist_raw.category_translation`)   AS raw_row_count,
  (SELECT COUNT(*) FROM `olist-analytics-500708.olist_clean.category_translation`) AS clean_row_count;
-- Expected: equal values (71)

-- V2. Grain / uniqueness check -- Portuguese name should be unique
-- (it's the join key back to products)
SELECT COUNT(*) AS total_rows, COUNT(DISTINCT category_name_portuguese) AS distinct_pt_names
FROM `olist-analytics-500708.olist_clean.category_translation`;
-- Expected: equal values

-- V3. Null profile
SELECT
  COUNTIF(category_name_portuguese IS NULL) AS null_pt,
  COUNTIF(category_name_english IS NULL)    AS null_en
FROM `olist-analytics-500708.olist_clean.category_translation`;
-- Expected: both 0

-- V4. Standardization check
SELECT COUNT(*) AS unstandardized_rows
FROM `olist-analytics-500708.olist_clean.category_translation`
WHERE category_name_portuguese != LOWER(TRIM(category_name_portuguese))
   OR category_name_english != LOWER(TRIM(category_name_english));
-- Expected: 0

-- V5. Referential integrity -- clean products -> clean category_translation
-- (re-confirm RI-10's 2-category gap still holds against the clean
-- version of both tables)
SELECT COUNT(DISTINCT p.product_category_name) AS categories_without_translation
FROM `olist-analytics-500708.olist_clean.products` p
LEFT JOIN `olist-analytics-500708.olist_clean.category_translation` t
  ON p.product_category_name = t.category_name_portuguese
WHERE p.product_category_name NOT IN ('unknown')  -- exclude the imputed placeholder, not a real category
  AND t.category_name_portuguese IS NULL;
-- Expected: 2 (matches RI-10 baseline)