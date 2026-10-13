#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-Debug}"
BUILD_ROOT="${HAHA_BUILD_ROOT:-$HOME/Library/Caches/HaHaTranslateDevelopment/XcodeBuild}"
if [ ! -d "$ROOT/Runtime/CHaHaRuntime.xcframework" ]; then
  "$ROOT/Scripts/build-runtime.sh"
fi
cd "$ROOT"
xcodegen generate
xcodebuild -project HaHaTranslate.xcodeproj -scheme HaHaTranslate -configuration "$MODE" \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$BUILD_ROOT" \
  CODE_SIGNING_ALLOWED=NO build
APP="$BUILD_ROOT/Build/Products/$MODE/HaHa翻译.app"
xattr -cr "$APP"
IDENTITY="${HAHA_SIGNING_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --options runtime --timestamp=none --entitlements "$ROOT/Config/HaHaTranslate.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
printf '%s\n' "$APP"
