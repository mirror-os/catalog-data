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
SOURCE=flatpak

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-push) PUSH=0; shift ;;
        --source)  SOURCE="$2"; shift 2 ;;
        *) echo "Usage: build-local.sh [--source flatpak|nix|nix-icons|all] [--no-push]" >&2; exit 1 ;;
    esac
done

# ── Check prerequisites ───────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }

[ -f "$UPDATE_SCRIPT" ] || die "mirror-catalog-update not found at $UPDATE_SCRIPT"
case "$SOURCE" in
    flatpak|nix|nix-icons|all) ;;
    *) die "Unknown source '$SOURCE' — must be flatpak, nix, nix-icons, or all" ;;
esac
if [[ "$SOURCE" == flatpak || "$SOURCE" == all ]]; then
    command -v flatpak &>/dev/null || die "flatpak not found"
    [ -f /var/lib/flatpak/appstream/flathub/x86_64/active/appstream.xml.gz ] \
        || die "Flathub AppStream cache not found — run: flatpak update --appstream"
fi
if [[ "$SOURCE" == nix || "$SOURCE" == all ]]; then
    command -v nix &>/dev/null || die "nix not found"
fi
if [[ "$SOURCE" == nix-icons ]]; then
    command -v nix-locate &>/dev/null || die "nix-locate not found — run inside: nix-shell -p nix-index"
fi

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

CATALOG_DB="$BUILD_HOME/.local/share/mirror-os/catalog.db"
MEDIA_DIR="$BUILD_HOME/.local/share/mirror-os/media"

mkdir -p "$MEDIA_DIR/icons" "$MEDIA_DIR/screenshots"

if [[ "$SOURCE" == nix-icons ]]; then
    # nix-icons runs the standalone Python script against the existing catalog.db
    [ -f "$CATALOG_DB" ] || die "catalog.db not found at $CATALOG_DB — run --source nix first"
    echo "Running nix-icons.py..."
    python3 "$REPO_ROOT/scripts/nix-icons.py" --db "$CATALOG_DB" --media-dir "$MEDIA_DIR"
else
    chmod +x "$UPDATE_SCRIPT"
    echo "Running mirror-catalog-update --source $SOURCE --no-media..."
    HOME="$BUILD_HOME" "$UPDATE_SCRIPT" --source "$SOURCE" --no-media
fi

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
if total > 0:
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
NIX_COUNT=$(python3 -c "
import sqlite3; conn = sqlite3.connect('catalog.db')
print(conn.execute('SELECT count(*) FROM nix_packages').fetchone()[0])
")
ICON_COUNT=$(ls "$MEDIA_DIR/icons/"*.png 2>/dev/null | wc -l)

NIX_ICON_COUNT=$(python3 -c "
import sqlite3; conn = sqlite3.connect('catalog.db')
try:
    print(conn.execute('SELECT count(*) FROM nix_packages WHERE icon_local_path != \"\"').fetchone()[0])
except Exception:
    print(0)
")

case "$SOURCE" in
    flatpak)
        COMMIT_MSG="catalog: update ${DATE} (${FLATPAK_COUNT} Flatpak apps, ${ICON_COUNT} icons)"
        ;;
    nix)
        COMMIT_MSG="catalog: update ${DATE} (${NIX_COUNT} Nix packages)"
        ;;
    nix-icons)
        COMMIT_MSG="catalog: update ${DATE} (${NIX_ICON_COUNT} Nix package icons)"
        ;;
    all)
        COMMIT_MSG="catalog: update ${DATE} (${FLATPAK_COUNT} Flatpak apps, ${NIX_COUNT} Nix packages, ${NIX_ICON_COUNT} Nix icons, ${ICON_COUNT} Flatpak icons)"
        ;;
esac

git commit -m "$COMMIT_MSG"

# ── Push ──────────────────────────────────────────────────────────────────────

if [ "$PUSH" -eq 1 ]; then
    git pull --rebase
    git push
    echo "Pushed to origin."
fi

echo "Done."
