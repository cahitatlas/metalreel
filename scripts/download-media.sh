#!/usr/bin/env bash
# Downloads the openly licensed sample clips used by examples/ and the benchmarks.
# Nothing here is committed to git — see ATTRIBUTION.md for sources and licenses.
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)/examples/public/media"
mkdir -p "$DIR"
fetch() { # name url
	if [[ -s "$DIR/$1" ]]; then echo "ok    $1"; return; fi
	echo "fetch $1"
	curl -fL --retry 3 --progress-bar -o "$DIR/$1.part" "$2" && mv "$DIR/$1.part" "$DIR/$1"
}
# Mixkit — Mixkit Stock Video Free License (https://mixkit.co/license/)
fetch talking-head.mp4 "https://assets.mixkit.co/videos/42323/42323-1080.mp4"   # Portrait of an influencer talking to the camera
fetch meadow.mp4       "https://assets.mixkit.co/videos/4075/4075-1080.mp4"     # Countryside meadow
fetch vertical.mp4     "https://assets.mixkit.co/videos/39874/39874-1080.mp4"   # Winter fashion (vertical)
# Wikimedia Commons — CC0 1.0
fetch ambient.wav "https://upload.wikimedia.org/wikipedia/commons/5/54/Paul_Kuniholm_Ambient_Seattle_2024_%28WayVSumtInThWay%29.wav"
echo "media ready in $DIR"

# Sample "photos" for the PhotoSlideshow composition: stills taken from the clips above.
IMG="$(dirname "$DIR")/img"; mkdir -p "$IMG"
TOOL="$(cd "$(dirname "$0")/.." && pwd)/.build/tools/extract-frame"
if [[ ! -x "$TOOL" ]]; then mkdir -p "$(dirname "$TOOL")"; swiftc -O "$(dirname "$0")/../tools/extract-frame.swift" -o "$TOOL"; fi
[[ -s "$IMG/photo-1.jpg" ]] || "$TOOL" "$DIR/meadow.mp4" 3 "$IMG/photo-1.jpg"
[[ -s "$IMG/photo-2.jpg" ]] || "$TOOL" "$DIR/meadow.mp4" 17 "$IMG/photo-2.jpg"
[[ -s "$IMG/photo-3.jpg" ]] || "$TOOL" "$DIR/vertical.mp4" 6 "$IMG/photo-3.jpg"
echo "photos ready in $IMG"
