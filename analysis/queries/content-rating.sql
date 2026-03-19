-- content-rating.sql — OARS content rating distribution
-- Useful for planning content filtering features in the Software Center.
-- Usage: sqlite3 catalog.db < analysis/queries/content-rating.sql

.headers on
.mode column

SELECT '=== Content rating distribution ===' AS '';
SELECT content_rating, COUNT(*) AS app_count
FROM flatpak_apps
GROUP BY content_rating
ORDER BY app_count DESC;

SELECT '' AS '';
SELECT '=== Apps rated "intense" (sample) ===' AS '';
SELECT app_id, name, categories
FROM flatpak_apps
WHERE content_rating = 'intense'
ORDER BY name
LIMIT 30;

SELECT '' AS '';
SELECT '=== Apps with no rating (empty content_rating) ===' AS '';
SELECT count(*) AS unrated
FROM flatpak_apps
WHERE content_rating = '' OR content_rating IS NULL;
