-- top-categories.sql — Category distribution across Flatpak apps
-- Useful for deciding which category filters to expose in the Software Center UI.
-- Usage: sqlite3 catalog.db < analysis/queries/top-categories.sql

.headers on
.mode column

SELECT cat.value AS category, COUNT(*) AS app_count
FROM flatpak_apps, json_each(flatpak_apps.categories) AS cat
GROUP BY category
ORDER BY app_count DESC;
