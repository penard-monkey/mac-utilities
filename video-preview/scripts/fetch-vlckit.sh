#!/bin/bash
# Fetch VideoLAN's official VLCKit 3.x macOS binary package, check its pinned
# SHA-256 and unpack VLCKit.framework into a vendor folder (default
# video-preview/Vendor, gitignored). The archive is cached in
# ~/.cache/mac-utilities/vlckit (VLCKIT_CACHE overrides it).
#
#   fetch-vlckit.sh [vendor-dir]
set -euo pipefail

VLCKIT_VERSION="3.7.3"
VLCKIT_URL="https://download.videolan.org/pub/cocoapods/prod/VLCKit-3.7.3-319ed2c0-79128878.tar.xz"
VLCKIT_SHA256="019afdae4e2e2d0f3ac325fac8f7ba0af25dca70b9d157df7d60db88e0be8e5d"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="${1:-$ROOT/Vendor}"
CACHE="${VLCKIT_CACHE:-$HOME/.cache/mac-utilities/vlckit}"
ARCHIVE="$CACHE/VLCKit-$VLCKIT_VERSION.tar.xz"
PACKAGE="VLCKit - binary package"

if [[ -f "$VENDOR/VLCKit.framework/Versions/A/VLCKit" && "$(cat "$VENDOR/.vlckit-sha256" 2>/dev/null)" == "$VLCKIT_SHA256" ]]; then
  exit 0
fi

mkdir -p "$CACHE"
if [[ ! -f "$ARCHIVE" ]]; then
  echo "Downloading VLCKit $VLCKIT_VERSION" >&2
  /usr/bin/curl -fsSL --retry 3 -o "$ARCHIVE.part" "$VLCKIT_URL"
  mv "$ARCHIVE.part" "$ARCHIVE"
fi
ACTUAL="$(/usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/awk '{print $1}')"
if [[ "$ACTUAL" != "$VLCKIT_SHA256" ]]; then
  rm -f "$ARCHIVE"
  echo "VLCKit SHA-256 mismatch: expected $VLCKIT_SHA256, got $ACTUAL" >&2
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vlckit.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
/usr/bin/tar -xJf "$ARCHIVE" -C "$WORK" \
  "$PACKAGE/VLCKit.xcframework/macos-arm64_x86_64/VLCKit.framework" "$PACKAGE/COPYING.txt"
rm -rf "$VENDOR"
mkdir -p "$VENDOR"
/usr/bin/ditto "$WORK/$PACKAGE/VLCKit.xcframework/macos-arm64_x86_64/VLCKit.framework" "$VENDOR/VLCKit.framework"
cp "$WORK/$PACKAGE/COPYING.txt" "$VENDOR/COPYING.txt"
echo "$VLCKIT_SHA256" > "$VENDOR/.vlckit-sha256"
