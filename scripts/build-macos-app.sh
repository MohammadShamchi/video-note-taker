#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="${PROJECT:-$ROOT_DIR/TutorScribeApp/TutorScribeApp.xcodeproj}"
SCHEME="${SCHEME:-TutorScribeApp}"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA="${DERIVED_DATA:-$ROOT_DIR/build/DerivedData}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
APP_NAME="${APP_NAME:-TutorScribeApp}"

mkdir -p "$DIST_DIR"

echo "Building $APP_NAME ($CONFIGURATION)..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -destination "platform=macOS" \
  build

BUILT_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
DIST_APP="$DIST_DIR/$APP_NAME.app"

if [[ ! -d "$BUILT_APP" ]]; then
  echo "Expected app was not built: $BUILT_APP" >&2
  exit 1
fi

rm -rf "$DIST_APP"
ditto "$BUILT_APP" "$DIST_APP"

echo "Built app: $DIST_APP"
