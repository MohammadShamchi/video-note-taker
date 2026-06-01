#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="${APP_NAME:-TutorScribeApp}"
VOLUME_NAME="${VOLUME_NAME:-TutorScribe}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
DMG_NAME="${DMG_NAME:-$APP_NAME.dmg}"
DMG_ROOT="$DIST_DIR/dmg-root"
DMG_PATH="$DIST_DIR/$DMG_NAME"

"$ROOT_DIR/scripts/build-macos-app.sh"

rm -rf "$DMG_ROOT"
mkdir -p "$DMG_ROOT"
ditto "$DIST_DIR/$APP_NAME.app" "$DMG_ROOT/$APP_NAME.app"
ln -s /Applications "$DMG_ROOT/Applications"

rm -f "$DMG_PATH"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$DMG_ROOT" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

rm -rf "$DMG_ROOT"

echo "Created DMG: $DMG_PATH"
