#!/bin/bash
# Генерує Resources/AppIcon.icns зі scripts/make-icon.swift
set -euo pipefail
cd "$(dirname "$0")/.."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
swift scripts/make-icon.swift "$TMP/master.png"

SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$TMP/master.png" --out "$SET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$TMP/master.png" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
cp "$TMP/master.png" Resources/AppIcon.png
echo "Готово: Resources/AppIcon.icns"
