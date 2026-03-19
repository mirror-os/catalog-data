# Analysis Queries

SQL queries for exploring the Mirror OS catalog database.

## Quick start

```bash
# Download the latest catalog.db
gh release download catalog-latest --repo mirror-os/catalog-data --pattern catalog.db

# Open interactively
sqlite3 catalog.db

# Run a specific query
sqlite3 catalog.db < queries/overview.sql
```

## Available queries

| File | Purpose |
|------|---------|
| `overview.sql` | Row counts, update timestamps, media coverage |
| `top-categories.sql` | Category distribution — which categories have the most apps |
| `missing-icons.sql` | Apps without cached icons — useful for debugging Phase 1/2 |
| `search-quality.sql` | FTS5 smoke tests: ranking, prefix match, phrase match, popularity sort |
| `app-map-coverage.sql` | Cross-source deduplication stats (Flatpak ↔ Nix matching) |
| `content-rating.sql` | OARS rating distribution — useful for content filter planning |
| `filtering-candidates.sql` | Advanced filter exploration: licenses, downloads, recency, keywords |

## Tips

```sql
-- FTS5 search (same algorithm as the Software Center)
SELECT id, name, bm25(catalog_fts) AS rank, monthly_downloads
FROM catalog_fts
LEFT JOIN flatpak_apps ON source = 'flatpak' AND id = app_id
WHERE catalog_fts MATCH 'video editor'
ORDER BY rank, COALESCE(monthly_downloads, 0) DESC
LIMIT 20;

-- JSON column expansion (categories, keywords, screenshots, releases)
SELECT app_id, cat.value AS category
FROM flatpak_apps, json_each(categories) AS cat
WHERE cat.value = 'Graphics'
ORDER BY name;

-- Parse the screenshots JSON
SELECT app_id, ss.value ->> 'url' AS screenshot_url
FROM flatpak_apps, json_each(screenshots) AS ss
LIMIT 20;
```

## Schema reference

See the [root README](../README.md#database-schema) for the full schema.
