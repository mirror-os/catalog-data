#!/usr/bin/env bash
# export-from-live.sh — Export catalog artifacts from a running Mirror OS system
#
# Run this on a live Mirror OS install that has a populated catalog database
# and media cache. Produces the same set of artifacts as the CI workflow, but
# with real screenshots included (the CI skips screenshot downloads).
#
# Usage:
#   ./export-from-live.sh [--output-dir /path/to/output]
#
# Output:
#   catalog.db        — portable SQLite database (machine-specific paths cleared)
#   icons.tar.zst     — all cached icons (extract into media/)
#   screenshots.tar.zst — all cached screenshots (extract into media/)
#
# Upload to the catalog-latest release with:
#   gh release upload catalog-latest --clobber catalog.db icons.tar.zst screenshots.tar.zst
#   --repo mirror-os/catalog-data

set -uo pipefail

CATALOG_DB="$HOME/.local/share/mirror-os/catalog.db"
MEDIA_DIR="$HOME/.local/share/mirror-os/media"
OUTPUT_DIR="${1:-$PWD/export-$(date -u '+%Y-%m-%d')}"

# ── Preflight checks ─────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }

[ -f "$CATALOG_DB" ] || die "catalog.db not found at $CATALOG_DB — run mirror-catalog-update first."
[ -d "$MEDIA_DIR/icons" ] || die "Icons directory not found at $MEDIA_DIR/icons"

FLATPAK_ROWS=$(python3 -c "
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
n = conn.execute('SELECT count(*) FROM flatpak_apps').fetchone()[0]
print(n)
conn.close()
" "$CATALOG_DB" 2>/dev/null) || die "catalog.db is not a valid Mirror OS catalog database."

[ "$FLATPAK_ROWS" -ge 100 ] || die "catalog.db has only $FLATPAK_ROWS flatpak_apps rows — looks incomplete."

ICON_COUNT=$(ls "$MEDIA_DIR/icons/"*.png 2>/dev/null | wc -l)
echo "Exporting: $FLATPAK_ROWS Flatpak apps, $ICON_COUNT icons"

# ── Prepare output ───────────────────────────────────────────────────────────

mkdir -p "$OUTPUT_DIR"
TMP_DB="$OUTPUT_DIR/catalog.db.tmp"

# ── Export catalog.db (with machine-specific paths neutralised) ──────────────

echo "Copying and sanitising catalog.db..."
cp "$CATALOG_DB" "$TMP_DB"

python3 - "$TMP_DB" << 'PYEOF'
import sqlite3, sys, json

db_path = sys.argv[1]
conn = sqlite3.connect(db_path, timeout=30)

with conn:
    # Clear icon_local_path — these are absolute paths on the source machine.
    # mirror-catalog-bootstrap repopulates them after extracting icons.tar.zst.
    conn.execute("UPDATE flatpak_apps SET icon_local_path = ''")

    # Clear local_path within the screenshots JSON array for the same reason.
    rows = conn.execute("SELECT app_id, screenshots FROM flatpak_apps WHERE screenshots != '[]'").fetchall()
    for app_id, ss_json in rows:
        try:
            screenshots = json.loads(ss_json)
            for s in screenshots:
                s['local_path'] = ''
            conn.execute(
                "UPDATE flatpak_apps SET screenshots = ? WHERE app_id = ?",
                (json.dumps(screenshots), app_id)
            )
        except Exception:
            pass

# Shrink the database file after updates
conn.execute("VACUUM")
conn.close()
print("  icon_local_path and screenshot local_path values cleared.")
PYEOF

mv "$TMP_DB" "$OUTPUT_DIR/catalog.db"
echo "  catalog.db: $(du -sh "$OUTPUT_DIR/catalog.db" | cut -f1)"

# ── Package icons ────────────────────────────────────────────────────────────

echo "Packaging icons..."
tar -C "$MEDIA_DIR" --zstd -cf "$OUTPUT_DIR/icons.tar.zst" icons/
echo "  icons.tar.zst: $(du -sh "$OUTPUT_DIR/icons.tar.zst" | cut -f1) ($ICON_COUNT files)"

# ── Package screenshots ──────────────────────────────────────────────────────

SS_COUNT=$(find "$MEDIA_DIR/screenshots" -name '*.jpg' 2>/dev/null | wc -l)
if [ "$SS_COUNT" -gt 0 ]; then
    echo "Packaging screenshots ($SS_COUNT files)..."
    tar -C "$MEDIA_DIR" --zstd -cf "$OUTPUT_DIR/screenshots.tar.zst" screenshots/
    echo "  screenshots.tar.zst: $(du -sh "$OUTPUT_DIR/screenshots.tar.zst" | cut -f1)"
else
    echo "No screenshots cached — creating empty archive."
    mkdir -p /tmp/empty-ss-export/screenshots
    tar -C /tmp/empty-ss-export --zstd -cf "$OUTPUT_DIR/screenshots.tar.zst" screenshots/
    rm -rf /tmp/empty-ss-export
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "=== Export complete ==="
ls -lh "$OUTPUT_DIR/"

echo ""
echo "To upload to the catalog-latest GitHub release:"
echo "  cd $OUTPUT_DIR"
echo "  gh release upload catalog-latest --clobber catalog.db icons.tar.zst screenshots.tar.zst --repo mirror-os/catalog-data"
