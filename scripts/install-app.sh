#!/bin/sh
# Builds marc and installs it over the copy the Dock and Finder launch.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
INSTALL_DIR=${MARC_INSTALL_DIR:-/Applications}
INSTALLED="$INSTALL_DIR/marc.app"

"$ROOT/scripts/build-app.sh"

if pgrep -f "$INSTALLED/Contents/MacOS/marc" >/dev/null 2>&1; then
    printf 'Quitting the running marc…\n'
    osascript -e 'tell application "marc" to quit' >/dev/null 2>&1 || true
    i=0
    while pgrep -f "$INSTALLED/Contents/MacOS/marc" >/dev/null 2>&1; do
        i=$((i + 1))
        if [ "$i" -gt 20 ]; then
            printf 'marc is still running; not replacing %s\n' "$INSTALLED" >&2
            exit 1
        fi
        /bin/sleep 0.5
    done
fi

rm -rf "$INSTALLED"
cp -R "$ROOT/dist/marc.app" "$INSTALLED"

# cp can carry the quarantine flag across, and the destination may inherit one
# from its parent. Clear it so Finder and the Dock launch the copy directly.
xattr -dr com.apple.quarantine "$INSTALLED" 2>/dev/null || true

printf 'Installed %s\n' "$INSTALLED"
