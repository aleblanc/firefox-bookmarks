#!/usr/bin/env bash
set -euo pipefail

# Directory holding this script (.../firelex-patch), regardless of where it is called from.
PATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Firefox tree to patch:
#   - CI (overlay): pass the upstream checkout root as $1 (e.g. "$GITHUB_WORKSPACE").
#   - Local dev in a full fork: no arg -> defaults to the parent of firelex-patch.
TARGET_ROOT="${1:-$(cd "$PATCH_DIR/.." && pwd)}"
ASSETS_DIR="$TARGET_ROOT/mobile/android/fenix/app/src/main/assets/extensions"

echo "[firelex-patch] Target Firefox tree: $TARGET_ROOT"

echo "[firelex-patch] Copying overlay files into the tree..."
cp -Rv "$PATCH_DIR/overlay/." "$TARGET_ROOT/"

echo "[firelex-patch] Unpacking bundled extensions into assets..."
declare -A EXT_MAP=(
  ["ublock_origin.xpi"]="ublock"
  ["symfony_bookmarks.xpi"]="symfony-bookmarks"
)
for xpi in "${!EXT_MAP[@]}"; do
  dest="$ASSETS_DIR/${EXT_MAP[$xpi]}"
  rm -rf "$dest"
  mkdir -p "$dest"
  unzip -o -q "$PATCH_DIR/extensions/$xpi" -d "$dest"
  test -f "$dest/manifest.json" || { echo "ERROR: manifest.json missing in $dest"; exit 1; }
done

# Stamp the real build version into the Symfony Bookmarks extension so its update banner
# can compare the *installed APK version* (not getBrowserInfo()'s GeckoView version, which
# lags version.txt in artifact mode and makes the banner false-positive/false-negative).
# This is the exact string the release is tagged with (browser/config/version.txt -> v<ver>
# in build-fenix.yml), so both sides of the comparison come from the same source.
SFB_DEST="$ASSETS_DIR/symfony-bookmarks"
VERSION_FILE="$TARGET_ROOT/browser/config/version.txt"
if [ -f "$VERSION_FILE" ]; then
  tr -d '[:space:]' < "$VERSION_FILE" > "$SFB_DEST/build-version.txt"
  echo "[firelex-patch] Stamped build-version.txt = $(cat "$SFB_DEST/build-version.txt")"
else
  echo "[firelex-patch] WARNING: $VERSION_FILE not found; extension update banner will fall back to getBrowserInfo()"
fi

echo "[firelex-patch] Applying source patches..."
shopt -s nullglob
for patch in "$PATCH_DIR"/patches/*.patch; do
  echo "  -> applying $(basename "$patch")"
  git -C "$TARGET_ROOT" apply --verbose "$patch"
done

echo "[firelex-patch] Done."
