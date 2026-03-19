-- overview.sql — Row counts, update timestamps, and coverage stats
-- Usage: sqlite3 catalog.db < analysis/queries/overview.sql

.headers on
.mode column

SELECT '=== Catalog sources ===' AS '';
SELECT source, row_count, updated_at FROM catalog_meta ORDER BY source;

SELECT '' AS '';
SELECT '=== Flatpak apps ===' AS '';
SELECT count(*) AS total_flatpak_apps FROM flatpak_apps;
SELECT count(*) AS with_icon
  FROM flatpak_apps WHERE icon_local_path != '';
SELECT count(*) AS with_screenshots
  FROM flatpak_apps WHERE screenshots != '[]';
SELECT count(*) AS verified
  FROM flatpak_apps WHERE verified = 1;
SELECT count(*) AS with_homepage
  FROM flatpak_apps WHERE homepage != '';
SELECT count(*) AS with_donation_url
  FROM flatpak_apps WHERE donation_url != '';

SELECT '' AS '';
SELECT '=== Nix packages ===' AS '';
SELECT count(*) AS total_nix_packages FROM nix_packages;
SELECT count(*) AS with_long_description
  FROM nix_packages WHERE long_description != '';
SELECT count(*) AS with_hm_module
  FROM nix_packages WHERE programs_name != '';

SELECT '' AS '';
SELECT '=== FTS index ===' AS '';
SELECT count(*) AS total_fts_rows FROM catalog_fts;
SELECT source, count(*) AS rows FROM catalog_fts GROUP BY source;

SELECT '' AS '';
SELECT '=== App map (cross-source deduplication) ===' AS '';
SELECT count(*) AS total_slugs FROM app_map;
SELECT
  SUM(CASE WHEN flatpak_id IS NOT NULL AND nix_attr IS NOT NULL THEN 1 ELSE 0 END) AS both_sources,
  SUM(CASE WHEN flatpak_id IS NOT NULL AND nix_attr IS NULL THEN 1 ELSE 0 END) AS flatpak_only,
  SUM(CASE WHEN flatpak_id IS NULL AND nix_attr IS NOT NULL THEN 1 ELSE 0 END) AS nix_only
FROM app_map;
