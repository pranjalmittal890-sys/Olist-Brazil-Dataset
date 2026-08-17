-- =====================================================================
-- CLEAN LAYER: geolocation
-- Source: olist_raw.geolocation ONLY (single-table dependency by design).
-- Purpose: Remove objectively invalid coordinates (out of Brazil's
--          bounding box), apply evidenced diacritic/case normalization
--          to reduce duplicate city naming, and flag unresolved
--          ambiguity. Grain is preserved as multiple-rows-per-zip --
--          aggregation to one-row-per-zip is explicitly deferred to
--          the serving/mart layer, consistent with how order_items and
--          order_payments aggregation was scoped elsewhere.
-- Note:    This is the ONE table in the clean layer where row removal
--          is performed, and it is justified the same way as the
--          products zero-weight imputation was: objective, physical
--          impossibility (a coordinate outside Brazil cannot be a
--          legitimate observation in a Brazil-only postal dataset),
--          not statistical unusualness.
-- =====================================================================

CREATE OR REPLACE TABLE `olist-analytics-500708.olist_clean.geolocation` AS

WITH bounded AS (

  -- Remove the 42 rows with coordinates outside Brazil's bounding box.
  -- Objectively invalid for this dataset's stated scope -- not a
  -- plausible edge case, not retained/flagged like every other anomaly
  -- in this project, because there is no legitimate business reason to
  -- keep a geographically impossible coordinate, and retaining it would
  -- silently corrupt any downstream AVG(lat)/AVG(lng) aggregation.
  SELECT *
  FROM `olist-analytics-500708.olist_raw.geolocation`
  WHERE geolocation_lat BETWEEN -34 AND 6
    AND geolocation_lng BETWEEN -75 AND -33
    AND geolocation_lat IS NOT NULL
    AND geolocation_lng IS NOT NULL

),

standardized AS (

  SELECT
    -- Zip code: cast to STRING and zero-pad to 5 digits, consistent
    -- with customer/seller zip handling.
    LPAD(CAST(geolocation_zip_code_prefix AS STRING), 5, '0') AS geolocation_zip_code_prefix,

    geolocation_lat,
    geolocation_lng,

    -- Evidenced normalization: TRIM + LOWER + diacritic removal.
    -- Profiling PROVED this reduces duplicate city naming for THIS
    -- table specifically (25.5% reduction, ~5,956 of ~8,556 affected
    -- zips resolved) -- unlike sellers, where the identical test was
    -- confirmed to have no effect. Applying it here is evidenced, not
    -- a copy-pasted assumption from another table.
    LOWER(
      TRANSLATE(
        TRIM(geolocation_city),
        'áàâãäéèêëíìîïóòôõöúùûüç',
        'aaaaaeeeeiiiiooooouuuuc'
      )
    ) AS geolocation_city,

    -- Defensive TRIM/UPPER, consistent with customer_state/seller_state.
    UPPER(TRIM(geolocation_state)) AS geolocation_state

  FROM bounded

),

-- Identify zip prefixes that STILL show more than one distinct city
-- even after normalization. Powers the ambiguity flag below. This is
-- a within-table aggregation (geolocation against itself), not a
-- cross-table join -- stays in scope for this layer.
unresolved_ambiguity AS (
  SELECT geolocation_zip_code_prefix
  FROM standardized
  GROUP BY geolocation_zip_code_prefix
  HAVING COUNT(DISTINCT geolocation_city) > 1
),

flagged AS (

  SELECT
    s.*,

    -- FLAG: this zip prefix still has more than one distinct city
    -- value even after diacritic/case normalization. Profiling
    -- finding: ~2,600 such zip prefixes remain unresolved. No further
    -- evidence exists to disambiguate from this table alone -- flagged
    -- rather than arbitrarily picking one city as "correct."
    -- Practical consequence: any AVG(lat)/AVG(lng) aggregation by zip
    -- at the serving/mart layer may span more than one actual city for
    -- these flagged rows -- a known, documented limitation.
    (ua.geolocation_zip_code_prefix IS NOT NULL)
        AS has_unresolved_city_ambiguity

  FROM standardized s
  LEFT JOIN unresolved_ambiguity ua
    ON s.geolocation_zip_code_prefix = ua.geolocation_zip_code_prefix

)

SELECT * FROM flagged;

-- V1. Row count comparison -- EXPECT A DECREASE of exactly 42 (the
-- only row-removal case in the entire clean layer)
SELECT
  (SELECT COUNT(*) FROM `olist-analytics-500708.olist_raw.geolocation`)   AS raw_row_count,
  (SELECT COUNT(*) FROM `olist-analytics-500708.olist_clean.geolocation`) AS clean_row_count,
  (SELECT COUNT(*) FROM `olist-analytics-500708.olist_raw.geolocation`)
    - (SELECT COUNT(*) FROM `olist-analytics-500708.olist_clean.geolocation`) AS rows_removed;
-- Expected: rows_removed = 42

-- V2. Bounding box validation -- confirm 0 out-of-bounds coordinates
-- remain post-cleaning
SELECT COUNTIF(
  geolocation_lat NOT BETWEEN -34 AND 6
  OR geolocation_lng NOT BETWEEN -75 AND -33
) AS remaining_out_of_bounds
FROM `olist-analytics-500708.olist_clean.geolocation`;
-- Expected: 0

-- V3. Null profile -- must remain 0 (no nulls should have been
-- introduced or should have existed)
SELECT
  COUNTIF(geolocation_zip_code_prefix IS NULL) AS null_zip,
  COUNTIF(geolocation_lat IS NULL)              AS null_lat,
  COUNTIF(geolocation_lng IS NULL)              AS null_lng,
  COUNTIF(geolocation_city IS NULL)             AS null_city,
  COUNTIF(geolocation_state IS NULL)            AS null_state
FROM `olist-analytics-500708.olist_clean.geolocation`;
-- Expected: all 0

-- V4. Zip format check
SELECT COUNT(*) AS malformed_zips
FROM `olist-analytics-500708.olist_clean.geolocation`
WHERE LENGTH(geolocation_zip_code_prefix) != 5
   OR NOT REGEXP_CONTAINS(geolocation_zip_code_prefix, r'^[0-9]{5}$');
-- Expected: 0

-- V5. Normalization effectiveness check -- confirm duplicate zip->city
-- count DECREASED relative to raw, consistent with profiling's proven
-- 25.5% reduction
SELECT COUNT(*) AS remaining_ambiguous_zips
FROM (
  SELECT geolocation_zip_code_prefix
  FROM `olist-analytics-500708.olist_clean.geolocation`
  GROUP BY geolocation_zip_code_prefix
  HAVING COUNT(DISTINCT geolocation_city) > 1
);
-- Expected: approximately 2,600 (matches profiling's reported
-- unresolved count -- NOT zero, since normalization only partially
-- resolves the issue)

-- V6. Flag count -- confirm has_unresolved_city_ambiguity count of
-- distinct zips matches V5
SELECT COUNT(DISTINCT geolocation_zip_code_prefix) AS flagged_ambiguous_zips
FROM `olist-analytics-500708.olist_clean.geolocation`
WHERE has_unresolved_city_ambiguity = TRUE;
-- Expected: matches V5 result exactly

-- V7. Standardization check -- confirm no diacritics remain in city field
SELECT COUNT(*) AS rows_with_diacritics
FROM `olist-analytics-500708.olist_clean.geolocation`
WHERE REGEXP_CONTAINS(geolocation_city, r'[áàâãäéèêëíìîïóòôõöúùûüç]');
-- Expected: 0

-- V8. Referential integrity coverage -- customers/sellers zip coverage
-- against the CLEAN geolocation table (re-run RI-11/RI-12 style checks
-- once customers/sellers clean tables are finalized, for completeness)
SELECT COUNT(DISTINCT c.customer_zip_code_prefix) AS customer_zips_missing_geo
FROM `olist-analytics-500708.olist_clean.customers` c
LEFT JOIN `olist-analytics-500708.olist_clean.geolocation` g
  ON c.customer_zip_code_prefix = g.geolocation_zip_code_prefix
WHERE g.geolocation_zip_code_prefix IS NULL;
-- Expected: close to the raw RI-11 baseline (157) -- may shift slightly
-- since 42 rows were removed; investigate if the count changes materially







