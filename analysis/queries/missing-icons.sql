-- missing-icons.sql — Apps without a cached icon
-- Useful for debugging Phase 1/2 icon coverage and spotting apps that need
-- attention (e.g. remote icon URL is broken, or icon_name is wrong).
-- Usage: sqlite3 catalog.db < analysis/queries/missing-icons.sql

.headers on
.mode column

SELECT '=== Apps missing icon_local_path ===' AS '';
SELECT app_id, name, icon_name,
       CASE WHEN screenshots LIKE '%"url"%' THEN 'has_remote_url' ELSE 'no_remote_url' END AS remote_icon
FROM flatpak_apps
WHERE icon_local_path = ''
ORDER BY name;

SELECT '' AS '';
SELECT '=== Summary ===' AS '';
SELECT
  count(*) AS total,
  SUM(CASE WHEN icon_local_path != '' THEN 1 ELSE 0 END) AS with_local_icon,
  SUM(CASE WHEN icon_local_path = '' AND icon_name != '' THEN 1 ELSE 0 END) AS missing_with_name,
  SUM(CASE WHEN icon_name = '' THEN 1 ELSE 0 END) AS no_icon_name
FROM flatpak_apps;
