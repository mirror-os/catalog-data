-- filtering-candidates.sql — Data exploration for advanced filtering features
-- Surfaces the fields available for filtering and their value distributions,
-- useful when designing filter UI (checkboxes, sliders, toggles).
-- Usage: sqlite3 catalog.db < analysis/queries/filtering-candidates.sql

.headers on
.mode column

-- How many distinct licenses are present?
SELECT '=== Top licenses ===' AS '';
SELECT license, COUNT(*) AS app_count
FROM flatpak_apps
WHERE license != ''
GROUP BY license
ORDER BY app_count DESC
LIMIT 20;

SELECT '' AS '';
SELECT '=== Apps with no license listed ===' AS '';
SELECT count(*) AS no_license FROM flatpak_apps WHERE license = '';

-- Download count distribution (for popularity sorting/filtering)
SELECT '' AS '';
SELECT '=== Monthly download distribution (percentiles) ===' AS '';
SELECT
  MIN(monthly_downloads) AS min_downloads,
  MAX(monthly_downloads) AS max_downloads,
  AVG(monthly_downloads) AS avg_downloads,
  -- rough quartiles
  (SELECT monthly_downloads FROM flatpak_apps WHERE monthly_downloads > 0
   ORDER BY monthly_downloads LIMIT 1 OFFSET
   (SELECT count(*) FROM flatpak_apps WHERE monthly_downloads > 0) / 4
  ) AS p25,
  (SELECT monthly_downloads FROM flatpak_apps WHERE monthly_downloads > 0
   ORDER BY monthly_downloads LIMIT 1 OFFSET
   (SELECT count(*) FROM flatpak_apps WHERE monthly_downloads > 0) / 2
  ) AS p50,
  (SELECT monthly_downloads FROM flatpak_apps WHERE monthly_downloads > 0
   ORDER BY monthly_downloads LIMIT 1 OFFSET
   (SELECT count(*) FROM flatpak_apps WHERE monthly_downloads > 0) * 3 / 4
  ) AS p75
FROM flatpak_apps;

SELECT '' AS '';
SELECT '=== Apps with zero monthly_downloads (no data) ===' AS '';
SELECT count(*) AS zero_downloads FROM flatpak_apps WHERE monthly_downloads = 0;

-- Verified status
SELECT '' AS '';
SELECT '=== Verified vs unverified ===' AS '';
SELECT verified, COUNT(*) AS count FROM flatpak_apps GROUP BY verified;

-- Release recency — how fresh is the catalog?
SELECT '' AS '';
SELECT '=== Apps by release year ===' AS '';
SELECT substr(release_date, 1, 4) AS release_year, COUNT(*) AS app_count
FROM flatpak_apps
WHERE release_date != ''
GROUP BY release_year
ORDER BY release_year DESC;

-- Keyword diversity (useful for keyword-based filtering)
SELECT '' AS '';
SELECT '=== Top keywords ===' AS '';
SELECT kw.value AS keyword, COUNT(*) AS app_count
FROM flatpak_apps, json_each(flatpak_apps.keywords) AS kw
WHERE kw.value != ''
GROUP BY keyword
ORDER BY app_count DESC
LIMIT 30;
