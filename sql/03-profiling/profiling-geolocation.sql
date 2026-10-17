select count(*) as row_cnt,
COUNT(DISTINCT geolocation_zip_code_prefix) AS distinct_zip_prefixes,
ROUND(COUNT(*) / COUNT(DISTINCT geolocation_zip_code_prefix), 2) AS avg_rows_per_zip,
count(distinct geolocation_city) as distinct_cities,
count(distinct geolocation_state) as distinct_states,
count(distinct geolocation_lat) as distinct_lat,
count(distinct geolocation_lng) as distinct_lng
FROM `olist-analytics-500708.olist_raw.geolocation`

-- Lat/lng range sanity (Brazil bounding box ~ lat -34 to 5, lng -74 to -34)
SELECT
  MIN(geolocation_lat) AS min_lat, MAX(geolocation_lat) AS max_lat,
  MIN(geolocation_lng) AS min_lng, MAX(geolocation_lng) AS max_lng,
  COUNTIF(geolocation_lat NOT BETWEEN -34 AND 6
       OR geolocation_lng NOT BETWEEN -75 AND -33) AS out_of_brazil_bbox
FROM `olist-analytics-500708.olist_raw.geolocation`

--Duplicate zip-city mapping
SELECT
geolocation_zip_code_prefix,
COUNT(DISTINCT geolocation_city)
FROM `olist-analytics-500708.olist_raw.geolocation`
GROUP BY geolocation_zip_code_prefix
HAVING COUNT(DISTINCT geolocation_city)>1;

SELECT
geolocation_zip_code_prefix,
ARRAY_AGG(DISTINCT geolocation_city ORDER BY geolocation_city) AS cities,
COUNT(*) AS sellers
FROM `olist-analytics-500708.olist_raw.geolocation`
GROUP BY geolocation_zip_code_prefix
HAVING COUNT(DISTINCT geolocation_city) > 1;

--same city, multiple states
SELECT
geolocation_city,
COUNT(DISTINCT geolocation_state)
FROM `olist-analytics-500708.olist_raw.geolocation`
GROUP BY geolocation_city
HAVING COUNT(DISTINCT geolocation_state)>1;

SELECT
geolocation_city,
ARRAY_AGG(DISTINCT geolocation_state ORDER BY geolocation_state) AS states,
COUNT(*) AS sellers
FROM `olist-analytics-500708.olist_raw.geolocation`
GROUP BY geolocation_city
HAVING COUNT(DISTINCT geolocation_state) > 1;

-- whitespace and lower are not the issue
SELECT
    COUNT(DISTINCT geolocation_city) AS original_cities,
    COUNT(DISTINCT LOWER(TRIM(geolocation_city))) AS normalized_cities
FROM `olist-analytics-500708.olist_raw.geolocation`;

SELECT
    COUNT(DISTINCT geolocation_city) AS original_cities,
    COUNT(
        DISTINCT LOWER(
            TRANSLATE(
                TRIM(geolocation_city),
                'áàâãäéèêëíìîïóòôõöúùûüç',
                'aaaaaeeeeiiiiooooouuuuc'
            )
        )
    ) AS normalized_cities
FROM `olist-analytics-500708.olist_raw.geolocation`;

SELECT
    LOWER(
        TRANSLATE(
            TRIM(geolocation_city),
            'áàâãäéèêëíìîïóòôõöúùûüç',
            'aaaaaeeeeiiiiooooouuuuc'
        )
    ) AS normalized_city,
    ARRAY_AGG(DISTINCT geolocation_city ORDER BY geolocation_city) AS original_variants,
    COUNT(*) AS rows_cnt
FROM `olist-analytics-500708.olist_raw.geolocation`
GROUP BY normalized_city
HAVING COUNT(DISTINCT geolocation_city) > 1
ORDER BY rows_cnt DESC;

SELECT
    COUNT(*) AS zip_prefixes_with_multiple_raw_cities,
    COUNTIF(raw_city_count > normalized_city_count) AS reduced_after_normalization
FROM (
    SELECT
        geolocation_zip_code_prefix,
        COUNT(DISTINCT geolocation_city) AS raw_city_count,
        COUNT(
            DISTINCT LOWER(
                TRANSLATE(
                    TRIM(geolocation_city),
                    'áàâãäéèëíìîïóòôõöúùûüç',
                    'aaaaaeeeeiiiiooooouuuuc'
                )
            )
        ) AS normalized_city_count
    FROM `olist-analytics-500708.olist_raw.geolocation`
    GROUP BY geolocation_zip_code_prefix
    HAVING COUNT(DISTINCT geolocation_city) > 1
);

SELECT
  g.geolocation_zip_code_prefix,
  COUNT(*) AS geo_rows,
  COUNT(DISTINCT c.customer_id) AS customers,
  COUNT(DISTINCT s.seller_id) AS sellers
FROM `olist-analytics-500708.olist_raw.geolocation` g
LEFT JOIN `olist-analytics-500708.olist_raw.customers` c
  ON g.geolocation_zip_code_prefix = c.customer_zip_code_prefix
LEFT JOIN `olist-analytics-500708.olist_raw.sellers` s
  ON g.geolocation_zip_code_prefix = s.seller_zip_code_prefix
WHERE g.geolocation_lat NOT BETWEEN -34 AND 6
   OR g.geolocation_lng NOT BETWEEN -75 AND -33
GROUP BY 1;
