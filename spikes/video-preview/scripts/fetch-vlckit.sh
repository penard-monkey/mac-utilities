#!/bin/bash
# Download VideoLAN's official VLCKit 3.x macOS binary package, verify its
# pinned SHA-256 and unpack VLCKit.framework into Vendor/. Never commit Vendor/.
set -euo pipefail

VLCKIT_VERSION="3.7.3"
VLCKIT_URL="https://download.videolan.org/pub/cocoapods/prod/VLCKit-3.7.3-319ed2c0-79128878.tar.xz"
VLCKIT_SHA256="019afdae4e2e2d0f3ac325fac8f7ba0af25dca70b9d157df7d60db88e0be8e5d"

root="$(cd "$(dirname "$0")/.." && pwd)"
vendor="$root/Vendor"
cache="${VLCKIT_CACHE:-$HOME/.cache/mac-utilities/vlckit}"
archive="$cache/VLCKit-$VLCKIT_VERSION.tar.xz"

if [ -f "$vendor/VLCKit.framework/Versions/A/VLCKit" ] && [ "$(cat "$vendor/.vlckit-sha256" 2>/dev/null)" = "$VLCKIT_SHA256" ]; then
  echo "VLCKit $VLCKIT_VERSION already in $vendor"
  exit 0
fi

mkdir -p "$cache"
if [ ! -f "$archive" ]; then
  /usr/bin/curl -fL --retry 3 -o "$archive.part" "$VLCKIT_URL"
  mv "$archive.part" "$archive"
fi

actual="$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')"
if [ "$actual" != "$VLCKIT_SHA256" ]; then
  echo "SHA-256 mismatch for $archive" >&2
  echo "  expected $VLCKIT_SHA256" >&2
  echo "  actual   $actual" >&2
  rm -f "$archive"
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
/usr/bin/tar -xJf "$archive" -C "$tmp" "VLCKit - binary package/VLCKit.xcframework/macos-arm64_x86_64/VLCKit.framework" "VLCKit - binary package/COPYING.txt"
rm -rf "$vendor"
mkdir -p "$vendor"
/usr/bin/ditto "$tmp/VLCKit - binary package/VLCKit.xcframework/macos-arm64_x86_64/VLCKit.framework" "$vendor/VLCKit.framework"
cp "$tmp/VLCKit - binary package/COPYING.txt" "$vendor/VLCKit-COPYING.txt"
echo "$VLCKIT_SHA256" > "$vendor/.vlckit-sha256"
echo "VLCKit $VLCKIT_VERSION -> $vendor/VLCKit.framework"
