-- search-quality.sql — FTS5 search smoke tests for common app names
-- Useful for validating the search ranking and tokenizer behaviour.
-- Usage: sqlite3 catalog.db < analysis/queries/search-quality.sql

.headers on
.mode column

-- Test 1: Exact app name match
SELECT '=== firefox ===' AS '';
SELECT f.source, f.id, fa.name, bm25(catalog_fts) AS bm25_rank, fa.monthly_downloads
FROM catalog_fts f
LEFT JOIN flatpak_apps fa ON f.source = 'flatpak' AND f.id = fa.app_id
WHERE catalog_fts MATCH 'firefox'
ORDER BY bm25_rank, COALESCE(fa.monthly_downloads, 0) DESC
LIMIT 10;

-- Test 2: Partial / prefix match
SELECT '' AS '';
SELECT '=== vide* (partial match) ===' AS '';
SELECT f.source, f.id, fa.name, bm25(catalog_fts) AS bm25_rank
FROM catalog_fts f
LEFT JOIN flatpak_apps fa ON f.source = 'flatpak' AND f.id = fa.app_id
WHERE catalog_fts MATCH 'vide*'
ORDER BY bm25_rank, COALESCE(fa.monthly_downloads, 0) DESC
LIMIT 10;

-- Test 3: Multi-word phrase
SELECT '' AS '';
SELECT '=== "video editor" (phrase) ===' AS '';
SELECT f.source, f.id, fa.name, bm25(catalog_fts) AS bm25_rank
FROM catalog_fts f
LEFT JOIN flatpak_apps fa ON f.source = 'flatpak' AND f.id = fa.app_id
WHERE catalog_fts MATCH '"video editor"'
ORDER BY bm25_rank, COALESCE(fa.monthly_downloads, 0) DESC
LIMIT 10;

-- Test 4: Popular apps (should rank highly)
SELECT '' AS '';
SELECT '=== spotify ===' AS '';
SELECT f.source, f.id, fa.name, bm25(catalog_fts) AS bm25_rank, fa.monthly_downloads
FROM catalog_fts f
LEFT JOIN flatpak_apps fa ON f.source = 'flatpak' AND f.id = fa.app_id
WHERE catalog_fts MATCH 'spotify'
ORDER BY bm25_rank, COALESCE(fa.monthly_downloads, 0) DESC
LIMIT 5;

-- Test 5: Download-count secondary sort — same BM25, different popularity
SELECT '' AS '';
SELECT '=== terminal (popularity sort) ===' AS '';
SELECT f.source, f.id, fa.name, bm25(catalog_fts) AS bm25_rank, fa.monthly_downloads
FROM catalog_fts f
LEFT JOIN flatpak_apps fa ON f.source = 'flatpak' AND f.id = fa.app_id
WHERE catalog_fts MATCH 'terminal'
ORDER BY bm25_rank, COALESCE(fa.monthly_downloads, 0) DESC
LIMIT 10;
