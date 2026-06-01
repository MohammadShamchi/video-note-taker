#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="${APP_NAME:-TutorScribeApp}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"

"$ROOT_DIR/scripts/build-macos-app.sh"

SOURCE_APP="$DIST_DIR/$APP_NAME.app"
TARGET_APP="$INSTALL_DIR/$APP_NAME.app"

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  echo "$APP_NAME is running. Quit it from the menu bar, then run this again." >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR"
rm -rf "$TARGET_APP"
ditto "$SOURCE_APP" "$TARGET_APP"

echo "Installed app: $TARGET_APP"
echo "Launch it from Finder, Spotlight, or with: open \"$TARGET_APP\""
