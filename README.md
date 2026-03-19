# Mirror OS Catalog Data

Weekly-updated snapshot of the Mirror OS app catalog database and media assets.

## Contents

| Path | Description |
|------|-------------|
| `catalog.db` | SQLite catalog database (Flatpak apps, Nix packages, FTS index) |
| `analysis/queries/` | SQL queries for exploring the catalog |
| `scripts/export-from-live.sh` | Export artifacts from a running Mirror OS system |

## Using catalog.db

```bash
# Open interactively
sqlite3 catalog.db

# Run a query
sqlite3 catalog.db "SELECT count(*) FROM flatpak_apps;"
sqlite3 catalog.db < analysis/queries/overview.sql

# Download the latest release artifacts
gh release download catalog-latest --repo mirror-os/catalog-data
```

## Database Schema

### `flatpak_apps`
All Flathub apps parsed from the local AppStream XML cache.

| Column | Type | Description |
|--------|------|-------------|
| `app_id` | TEXT PK | Flatpak application ID (e.g. `org.mozilla.firefox`) |
| `name` | TEXT | Display name |
| `summary` | TEXT | One-line description |
| `description` | TEXT | Long description |
| `version` | TEXT | Latest version |
| `release_date` | TEXT | Release date (ISO-8601) |
| `release_timestamp` | INTEGER | Unix timestamp of latest release |
| `developer` | TEXT | Developer/publisher name |
| `license` | TEXT | SPDX license identifier |
| `homepage` | TEXT | Project homepage URL |
| `bugtracker_url` | TEXT | Bug tracker URL |
| `donation_url` | TEXT | Donation URL |
| `categories` | TEXT | JSON array of AppStream categories |
| `keywords` | TEXT | JSON array of search keywords |
| `icon_name` | TEXT | AppStream icon name |
| `screenshots` | TEXT | JSON array of `{local_path, url, caption, width, height}` |
| `content_rating` | TEXT | `all` / `moderate` / `intense` (OARS rating) |
| `flatpak_ref` | TEXT | Flatpak ref string |
| `releases_json` | TEXT | JSON array of `{version, timestamp, description}` |
| `verified` | INTEGER | 1 if Flathub-verified developer |
| `monthly_downloads` | INTEGER | Monthly download count |
| `icon_local_path` | TEXT | Local path to cached icon PNG |

### `nix_packages`
Packages from nixpkgs, enriched with Home Manager module metadata.

| Column | Type | Description |
|--------|------|-------------|
| `attr` | TEXT PK | Nix attribute path (e.g. `pkgs.firefox`) |
| `pname` | TEXT | Package name |
| `version` | TEXT | Package version |
| `description` | TEXT | Short description |
| `long_description` | TEXT | Long description (from `meta.longDescription`) |
| `homepage` | TEXT | Homepage URL |
| `license` | TEXT | License string |
| `maintainers` | TEXT | JSON array of GitHub usernames |
| `programs_name` | TEXT | Home Manager `programs.*` module name (if any) |
| `hm_options_json` | TEXT | Pre-baked HM option schema JSON |

### `catalog_fts` (FTS5 virtual table)
Full-text search index over all app sources.

| Column | Description |
|--------|-------------|
| `source` | `flatpak` or `nix` |
| `id` | `app_id` or `attr` |
| `name` | App name |
| `description` | Description text |
| `developer` | Developer name |
| `categories` | Space-separated categories |

Query with: `SELECT * FROM catalog_fts WHERE catalog_fts MATCH 'firefox' ORDER BY rank`

### `app_map`
Cross-source deduplication — maps a canonical slug to its Flatpak and/or Nix entries.

| Column | Type | Description |
|--------|------|-------------|
| `slug` | TEXT PK | Derived canonical slug (e.g. `firefox`) |
| `flatpak_id` | TEXT | Flatpak app_id (NULL if Nix-only) |
| `nix_attr` | TEXT | Nix attr (NULL if Flatpak-only) |
| `display_name` | TEXT | Human-readable name |
| `preferred_source` | TEXT | `flatpak` or `nix` |

### `catalog_meta`
Timestamps and row counts for each catalog source.

| Column | Type | Description |
|--------|------|-------------|
| `source` | TEXT PK | `flatpak`, `nix`, `nix-meta`, `hm-options` |
| `updated_at` | TEXT | ISO-8601 timestamp of last update |
| `row_count` | INTEGER | Number of rows processed |

## Release Artifacts

Each weekly CI run attaches these files to the `catalog-latest` GitHub Release:

| File | Description |
|------|-------------|
| `catalog.db` | SQLite database (Flatpak apps + Nix packages) |
| `icons.tar.zst` | All app icons as `icons/{app_id}.png` |
| `screenshots.tar.zst` | Screenshots as `screenshots/{app_id}/0.jpg`, `1.jpg`, … |

The archives extract directly into `~/.local/share/mirror-os/media/` with the correct folder structure.

## Bootstrap Integration

On a new Mirror OS install, `mirror-catalog-bootstrap` downloads these release artifacts before the catalog update timer runs, so the Software Center is populated immediately without a 30+ minute local build.

## Update Schedule

CI runs every **Monday at 02:00 UTC** and on manual dispatch. The `catalog-latest` release is replaced in-place; dated releases (e.g. `catalog-2026-03-17`) are kept for historical reference.
