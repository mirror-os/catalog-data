-- app-map-coverage.sql — Cross-source deduplication stats and quality checks
-- Useful for understanding how well Flatpak and Nix apps are being matched.
-- Usage: sqlite3 catalog.db < analysis/queries/app-map-coverage.sql

.headers on
.mode column

SELECT '=== Overall deduplication coverage ===' AS '';
SELECT
  COUNT(*) AS total_slugs,
  SUM(CASE WHEN flatpak_id IS NOT NULL AND nix_attr IS NOT NULL THEN 1 ELSE 0 END) AS both_sources,
  SUM(CASE WHEN flatpak_id IS NOT NULL AND nix_attr IS NULL THEN 1 ELSE 0 END) AS flatpak_only,
  SUM(CASE WHEN flatpak_id IS NULL AND nix_attr IS NOT NULL THEN 1 ELSE 0 END) AS nix_only
FROM app_map;

SELECT '' AS '';
SELECT '=== Apps with both Flatpak and Nix entries (sample) ===' AS '';
SELECT slug, flatpak_id, nix_attr, preferred_source
FROM app_map
WHERE flatpak_id IS NOT NULL AND nix_attr IS NOT NULL
ORDER BY slug
LIMIT 30;

SELECT '' AS '';
SELECT '=== Preferred source distribution ===' AS '';
SELECT preferred_source, COUNT(*) AS count
FROM app_map
GROUP BY preferred_source;

SELECT '' AS '';
SELECT '=== Slugs where Nix is preferred (may be worth investigating) ===' AS '';
SELECT slug, flatpak_id, nix_attr
FROM app_map
WHERE preferred_source = 'nix' AND flatpak_id IS NOT NULL
ORDER BY slug
LIMIT 20;
