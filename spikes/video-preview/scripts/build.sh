#!/bin/bash
# Build the spike with xcodebuild (unsigned), then sign inside-out:
# VLCKit.framework -> .appex (with its entitlements) -> .app (with its entitlements).
#
#   build.sh <output-dir>
#
# SIGN_IDENTITY (default "-", ad hoc) and SIGN_KEYCHAIN select the identity.
# EXT_ENTITLEMENTS overrides the appex entitlements file (experiment 4).
# LAYOUT=dylib replaces the embedded VLCKit.framework (which contains symlinks)
# with a flat Contents/Frameworks/VLCKit.dylib, because the release archiver and
# installer refuse symlinks.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:?usage: build.sh <output-dir>}"
identity="${SIGN_IDENTITY:--}"
ext_entitlements="${EXT_ENTITLEMENTS:-$root/PreviewExtension/PreviewExtension.entitlements}"
app_entitlements="$root/App/App.entitlements"

/bin/bash "$root/scripts/fetch-vlckit.sh"

mkdir -p "$out"
out="$(cd "$out" && pwd)"
/usr/bin/xcodebuild -project "$root/VideoPreviewSpike.xcodeproj" -scheme VideoPreviewSpike \
  -configuration Release -destination 'generic/platform=macOS' -derivedDataPath "$out/DerivedData" \
  CODE_SIGNING_ALLOWED=NO build >"$out/xcodebuild.log" 2>&1 || {
  /usr/bin/grep -E 'error:' "$out/xcodebuild.log" | /usr/bin/sort -u >&2
  echo "xcodebuild failed; see $out/xcodebuild.log" >&2
  exit 1
}

app="$out/DerivedData/Build/Products/Release/Video Preview Spike.app"
[ -d "$app" ] || { echo "build failed: no $app" >&2; exit 1; }
rm -rf "$out/Video Preview Spike.app"
/usr/bin/ditto "$app" "$out/Video Preview Spike.app"
app="$out/Video Preview Spike.app"
appex="$app/Contents/PlugIns/VideoPreviewSpikePreview.appex"
framework="$appex/Contents/Frameworks/VLCKit.framework"

if [ "${LAYOUT:-framework}" = dylib ]; then
  old_id="@loader_path/../Frameworks/VLCKit.framework/Versions/A/VLCKit"
  dylib="$appex/Contents/Frameworks/VLCKit.dylib"
  cp "$framework/Versions/A/VLCKit" "$dylib"
  rm -rf "$framework"
  /usr/bin/install_name_tool -id "@rpath/VLCKit.dylib" "$dylib" 2>/dev/null
  /usr/bin/install_name_tool -change "$old_id" "@rpath/VLCKit.dylib" "$appex/Contents/MacOS/VideoPreviewSpikePreview" 2>/dev/null
  framework="$dylib"
fi

set -- --force --sign "$identity" --timestamp=none
if [ -n "${SIGN_KEYCHAIN:-}" ]; then set -- "$@" --keychain "$SIGN_KEYCHAIN"; fi

/usr/bin/codesign "$@" "$framework"
/usr/bin/codesign "$@" --entitlements "$ext_entitlements" "$appex"
/usr/bin/codesign "$@" --entitlements "$app_entitlements" "$app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"

( cd "$out" && rm -f "Video Preview Spike.zip" && /usr/bin/ditto -c -k --keepParent "Video Preview Spike.app" "Video Preview Spike.zip" )
echo "$app"
