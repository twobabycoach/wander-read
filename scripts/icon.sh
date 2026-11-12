#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/module-cache .build/AppIcon.iconset Design
swift -module-cache-path .build/module-cache scripts/make-icon.swift .build/icon.png
for n in 16 32 128 256 512; do
  sips -z "$n" "$n" .build/icon.png --out ".build/AppIcon.iconset/icon_${n}x${n}.png" >/dev/null
  double=$((n * 2))
  sips -z "$double" "$double" .build/icon.png --out ".build/AppIcon.iconset/icon_${n}x${n}@2x.png" >/dev/null
done
python3 scripts/pack-icon.py
