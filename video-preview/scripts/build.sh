#!/bin/bash
# Build Video Preview.app (host app + Quick Look preview extension) with
# xcodebuild, embed VLCKit as one flat dylib (release archives refuse the
# framework's symlinks) and sign inside out, ad hoc:
# VLCKit.dylib -> .appex (sandbox entitlements) -> .app.
#
#   build.sh --output <dir> [--version X.Y.Z] [--dev] [--vendor <dir>]
#            [--scratch <dir>] [--license <file>]
#
# --dev builds "Video Preview Dev.app" with distinct bundle identifiers so it
# can be tried next to (or without touching) an installed release.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="" VERSION="" DEV=0 VENDOR="$ROOT/Vendor" SCRATCH="" LICENSE="$ROOT/../LICENSE"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) OUTPUT="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --dev) DEV=1; shift ;;
    --vendor) VENDOR="$2"; shift 2 ;;
    --scratch) SCRATCH="$2"; shift 2 ;;
    --license) LICENSE="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$OUTPUT" ]] || { echo "usage: build.sh --output <dir> [--version X.Y.Z] [--dev]" >&2; exit 2; }
if [[ -z "$VERSION" ]]; then
  VERSION="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$ROOT/mac-utility.json")"
fi
if [[ "$DEV" == 1 ]]; then
  NAME="Video Preview Dev" BUNDLE_ID="com.mac-utilities.video-preview.dev"
else
  NAME="Video Preview" BUNDLE_ID="com.mac-utilities.video-preview"
fi

/bin/bash "$ROOT/scripts/fetch-vlckit.sh" "$VENDOR"
VENDOR="$(cd "$VENDOR" && pwd)"
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"
if [[ -z "$SCRATCH" ]]; then
  SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/video-preview-build.XXXXXX")"
  trap 'rm -rf "$SCRATCH"' EXIT
fi
mkdir -p "$SCRATCH"
LOG="$SCRATCH/xcodebuild.log"

if ! /usr/bin/xcodebuild -project "$ROOT/VideoPreview.xcodeproj" -scheme VideoPreview \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$SCRATCH/DerivedData" \
    CODE_SIGNING_ALLOWED=NO VLCKIT_DIR="$VENDOR" \
    APP_PRODUCT_NAME="$NAME" APP_BUNDLE_ID="$BUNDLE_ID" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$VERSION" \
    build >"$LOG" 2>&1; then
  /usr/bin/grep -E 'error:' "$LOG" | /usr/bin/sort -u >&2 || /usr/bin/tail -40 "$LOG" >&2
  echo "xcodebuild failed; full log: $LOG" >&2
  exit 1
fi

BUILT="$SCRATCH/DerivedData/Build/Products/Release/$NAME.app"
APP="$OUTPUT/$NAME.app"
rm -rf "$APP"
/usr/bin/ditto "$BUILT" "$APP"
APPEX="$APP/Contents/PlugIns/VideoPreviewQuickLook.appex"
EXT_BIN="$APPEX/Contents/MacOS/VideoPreviewQuickLook"
DYLIB="$APPEX/Contents/Frameworks/VLCKit.dylib"
RESOURCES="$APP/Contents/Resources"

# Embed VLCKit as a flat dylib and point the extension at it.
mkdir -p "$APPEX/Contents/Frameworks"
cp "$VENDOR/VLCKit.framework/Versions/A/VLCKit" "$DYLIB"
chmod 755 "$DYLIB"
OLD_ID="$(/usr/bin/otool -D -arch arm64 "$DYLIB" | /usr/bin/tail -1)"
/usr/bin/install_name_tool -id "@rpath/VLCKit.dylib" "$DYLIB" 2>/dev/null
/usr/bin/install_name_tool -change "$OLD_ID" "@rpath/VLCKit.dylib" "$EXT_BIN" 2>/dev/null
if /usr/bin/otool -L "$EXT_BIN" | /usr/bin/grep -q 'VLCKit.framework'; then
  echo "Extension still links VLCKit.framework" >&2; exit 1
fi

# Resources: icon, licenses and third-party notice.
mkdir -p "$RESOURCES"
cp "$ROOT/Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$RESOURCES/THIRD_PARTY_NOTICES.md"
cp "$ROOT/licenses/LGPL-2.1.txt" "$RESOURCES/VLCKit-LGPL-2.1.txt"
if [[ -f "$LICENSE" ]]; then cp "$LICENSE" "$RESOURCES/LICENSE"; fi

if [[ -n "$(/usr/bin/find "$APP" -type l)" ]]; then
  echo "Bundle contains symlinks" >&2; exit 1
fi

set -- --force --sign - --timestamp=none
/usr/bin/codesign "$@" "$DYLIB"
/usr/bin/codesign "$@" --entitlements "$ROOT/QuickLookExtension/QuickLookExtension.entitlements" "$APPEX"
/usr/bin/codesign "$@" "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"
echo "$APP"
