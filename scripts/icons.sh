#!/bin/sh
# Regenerates Sources/Caton/Resources from logo.png and icon-*.png at the
# repository root. Run after changing any of those images.
set -e
cd "$(dirname "$0")/.."
work=$(mktemp -d)
swiftc -O -o "$work/icons" scripts/icons.swift
"$work/icons" "$PWD" "$work/AppIcon.iconset"
iconutil -c icns "$work/AppIcon.iconset" -o Sources/Caton/Resources/AppIcon.icns
rm -r "$work"
echo "Rendered Sources/Caton/Resources"
