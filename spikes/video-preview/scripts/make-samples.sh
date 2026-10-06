#!/bin/bash
# Generate synthetic sample media (test pattern + sine tone) for previewing.
set -euo pipefail
out="${1:?usage: make-samples.sh <output-dir>}"
ffmpeg="${FFMPEG:-/opt/homebrew/bin/ffmpeg}"
mkdir -p "$out"
"$ffmpeg" -hide_banner -loglevel error -y \
  -f lavfi -i testsrc2=size=640x360:rate=30:duration=6 -f lavfi -i sine=frequency=440:duration=6 \
  -c:v libvpx-vp9 -b:v 500k -c:a libopus "$out/sample-vp9-opus.webm"
"$ffmpeg" -hide_banner -loglevel error -y \
  -f lavfi -i testsrc=size=640x360:rate=30:duration=6 -f lavfi -i sine=frequency=660:duration=6 \
  -c:v libx264 -pix_fmt yuv420p -c:a aac "$out/sample-h264-aac.mkv"
ls -l "$out"
