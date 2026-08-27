#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/dist/marc.app"
ICONSET="$ROOT/.build/marc.iconset"
ARM_BINARY="$ROOT/.build/arm64-apple-macosx/release/marc"
INTEL_BINARY="$ROOT/.build/x86_64-apple-macosx/release/marc"
APP_BINARY="$APP/Contents/MacOS/marc"

cd "$ROOT"
swift build -c release --arch arm64 --product marc
swift build -c release --arch x86_64 --product marc

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swift "$ROOT/scripts/generate-icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/marc.icns"
lipo -create "$ARM_BINARY" "$INTEL_BINARY" -output "$APP_BINARY"
cp "$ROOT/AppBundle/Info.plist" "$APP/Contents/Info.plist"
chmod +x "$APP_BINARY"
codesign --force --deep --sign - "$APP"

printf 'Built %s\n' "$APP"
