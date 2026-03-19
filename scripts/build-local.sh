#!/usr/bin/env bash
# build-local.sh — Build and commit catalog.db from the local Flatpak AppStream cache
#
# Runs mirror-catalog-update (Phase 1 only) using the system Flatpak's AppStream
# cache, then commits catalog.db to the repo and optionally pushes.
#
# Usage:
#   ./scripts/build-local.sh             # build, commit, push
#   ./scripts/build-local.sh --no-push   # build and commit only

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN_REPO="$(cd "$REPO_ROOT/../main" && pwd)"
UPDATE_SCRIPT="$MAIN_REPO/files/usr/libexec/mirror-os/mirror-catalog-update"
BUILD_HOME=/tmp/catalog-local-build
PUSH=1

for arg in "$@"; do
    [ "$arg" = "--no-push" ] && PUSH=0
done

# ── Check prerequisites ───────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }

[ -f "$UPDATE_SCRIPT" ] || die "mirror-catalog-update not found at $UPDATE_SCRIPT"
command -v flatpak &>/dev/null || die "flatpak not found"
[ -f /var/lib/flatpak/appstream/flathub/x86_64/active/appstream.xml.gz ] \
    || die "Flathub AppStream cache not found — run: flatpak update --appstream"

# Locate python3 — try PATH first, fall back to nix
PYTHON3=$(command -v python3 2>/dev/null || true)
if [ -z "$PYTHON3" ]; then
    echo "python3 not in PATH — resolving via nix..."
    NIX_PYTHON=$(nix build nixpkgs#python3 --no-link --print-out-paths 2>/dev/null)/bin
    export PATH="$NIX_PYTHON:$PATH"
    PYTHON3=$(command -v python3 2>/dev/null) || die "python3 not available (tried nix too)"
fi
echo "Using: $(python3 --version)"

# ── Build ─────────────────────────────────────────────────────────────────────

mkdir -p "$BUILD_HOME/.local/share/mirror-os/media/icons" \
         "$BUILD_HOME/.local/share/mirror-os/media/screenshots"

chmod +x "$UPDATE_SCRIPT"
echo "Running mirror-catalog-update --source flatpak --no-media..."
HOME="$BUILD_HOME" "$UPDATE_SCRIPT" --source flatpak --no-media

CATALOG_DB="$BUILD_HOME/.local/share/mirror-os/catalog.db"
MEDIA_DIR="$BUILD_HOME/.local/share/mirror-os/media"

# ── Summary ───────────────────────────────────────────────────────────────────

python3 - "$CATALOG_DB" << 'EOF'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
for source, updated_at, row_count in conn.execute(
    "SELECT source, updated_at, row_count FROM catalog_meta ORDER BY source"
):
    print(f"  {source}: {row_count} rows  ({updated_at})")
icons = conn.execute("SELECT count(*) FROM flatpak_apps WHERE icon_local_path != ''").fetchone()[0]
total = conn.execute("SELECT count(*) FROM flatpak_apps").fetchone()[0]
print(f"  icons cached: {icons}/{total}")
conn.close()
EOF
echo "  catalog.db: $(du -sh "$CATALOG_DB" | cut -f1)"
echo "  icons dir:  $(ls "$MEDIA_DIR/icons/"*.png 2>/dev/null | wc -l) files"

# ── Commit ────────────────────────────────────────────────────────────────────

cp "$CATALOG_DB" "$REPO_ROOT/catalog.db"

cd "$REPO_ROOT"
git add catalog.db
if git diff --cached --quiet; then
    echo "catalog.db unchanged — nothing to commit."
    exit 0
fi

DATE=$(date -u '+%Y-%m-%d')
FLATPAK_COUNT=$(python3 -c "
import sqlite3; conn = sqlite3.connect('catalog.db')
print(conn.execute('SELECT count(*) FROM flatpak_apps').fetchone()[0])
")
ICON_COUNT=$(ls "$MEDIA_DIR/icons/"*.png 2>/dev/null | wc -l)

git commit -m "catalog: update ${DATE} (${FLATPAK_COUNT} Flatpak apps, ${ICON_COUNT} icons)"

# ── Push ──────────────────────────────────────────────────────────────────────

if [ "$PUSH" -eq 1 ]; then
    git pull --rebase
    git push
    echo "Pushed to origin."
fi

echo "Done."
