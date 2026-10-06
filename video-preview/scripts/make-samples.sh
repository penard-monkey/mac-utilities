#!/bin/bash
# Generate synthetic samples (test pattern + sine tone) for manual checks.
# Media is never committed.
#
#   make-samples.sh <output-dir>
set -euo pipefail
OUT="${1:?usage: make-samples.sh <output-dir>}"
FFMPEG="${FFMPEG:-/opt/homebrew/bin/ffmpeg}"
mkdir -p "$OUT"
sample() {
  local name="$1"; shift
  "$FFMPEG" -hide_banner -loglevel error -y \
    -f lavfi -i testsrc2=size=640x360:rate=30:duration=6 -f lavfi -i sine=frequency=440:duration=6 \
    "$@" "$OUT/$name"
}
sample sample-vp9-opus.webm -c:v libvpx-vp9 -b:v 500k -c:a libopus
sample sample-h264-aac.mkv -c:v libx264 -pix_fmt yuv420p -c:a aac
sample sample-mpeg4-mp3.avi -c:v mpeg4 -q:v 5 -c:a libmp3lame
sample sample-h264-aac.flv -c:v libx264 -pix_fmt yuv420p -c:a aac -ar 44100
sample sample-wmv2-wma.wmv -c:v wmv2 -b:v 800k -c:a wmav2
ls -l "$OUT"
