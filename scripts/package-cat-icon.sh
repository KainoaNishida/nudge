#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOURCE_DIR="$1"
ICONSET_DIR="$RESOURCE_DIR/NudgeCat.iconset"

mkdir -p "$RESOURCE_DIR" "$ICONSET_DIR"
python3 "$ROOT_DIR/scripts/generate-cat-icon.py" "$RESOURCE_DIR/NudgeCat.png"

for entry in \
  "16 icon_16x16.png" \
  "32 icon_16x16@2x.png" \
  "32 icon_32x32.png" \
  "64 icon_32x32@2x.png" \
  "128 icon_128x128.png" \
  "256 icon_128x128@2x.png" \
  "256 icon_256x256.png" \
  "512 icon_256x256@2x.png" \
  "512 icon_512x512.png"; do
  read -r size name <<< "$entry"
  sips -z "$size" "$size" "$RESOURCE_DIR/NudgeCat.png" --out "$ICONSET_DIR/$name" >/dev/null
done
cp "$RESOURCE_DIR/NudgeCat.png" "$ICONSET_DIR/icon_512x512@2x.png"
python3 "$ROOT_DIR/scripts/generate-cat-icon.py" pack "$ICONSET_DIR" "$RESOURCE_DIR/NudgeCat.icns"
rm -rf "$ICONSET_DIR"
