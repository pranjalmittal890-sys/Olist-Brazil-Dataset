select count(*) as row_cnt,
count(distinct string_field_0) as cat_name,
count(distinct string_field_1) as cat_name_eng,
countif(string_field_0 is null) as null_cat_name,
countif(string_field_1 is null) as null_cat_name_eng
FROM `olist-analytics-500708.olist_raw.category_translation`

select * FROM `olist-analytics-500708.olist_raw.category_translation`

-- Coverage check: which product categories have NO English translation?
SELECT DISTINCT p.product_category_name
FROM `olist-analytics-500708.olist_raw.products` p
LEFT JOIN `olist-analytics-500708.olist_raw.category_translation` t
  ON p.product_category_name = t.string_field_0
WHERE p.product_category_name IS NOT NULL
  AND t.string_field_0 IS NULL;

-- unused translations
SELECT
t.string_field_0,
t.string_field_1
FROM `olist-analytics-500708.olist_raw.category_translation` t
LEFT JOIN `olist-analytics-500708.olist_raw.products` p
ON t.string_field_0 = p.product_category_name
WHERE p.product_category_name IS NULL;