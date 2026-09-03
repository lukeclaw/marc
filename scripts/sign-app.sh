#!/bin/sh
# Signs a built marc.app so macOS launches it without the Gatekeeper
# "unauthenticated app" dialog.
#
# Signing identity resolution, in order:
#   1. $MARC_SIGN_IDENTITY, if set (a name or SHA-1 from `security find-identity`)
#   2. a "Developer ID Application" certificate in the keychain
#   3. an "Apple Development" certificate in the keychain
#   4. ad-hoc ("-"), which still launches locally but changes hash every build
set -eu

APP=$1

resolve_identity() {
    if [ -n "${MARC_SIGN_IDENTITY:-}" ]; then
        printf '%s\n' "$MARC_SIGN_IDENTITY"
        return
    fi

    identities=$(security find-identity -v -p codesigning 2>/dev/null || true)

    for prefix in 'Developer ID Application' 'Apple Development'; do
        hash=$(printf '%s\n' "$identities" \
            | grep -F "\"$prefix" \
            | head -n 1 \
            | awk '{print $2}')
        if [ -n "$hash" ]; then
            printf '%s\n' "$hash"
            return
        fi
    done

    printf -- '-\n'
}

IDENTITY=$(resolve_identity)

if [ "$IDENTITY" = "-" ]; then
    printf 'sign-app: no signing certificate found; falling back to ad-hoc.\n' >&2
else
    printf 'sign-app: signing with %s\n' "$IDENTITY"
fi

# --timestamp=none keeps local builds working offline. A notarized release
# build needs a real timestamp, so drop that flag if you ever notarize.
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"

# The bundle picks up com.apple.quarantine whenever it travels through AirDrop,
# a browser, an archive, or iCloud. Gatekeeper only shows the "unauthenticated
# app" dialog for quarantined bundles, so clear it on every build.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

codesign --verify --strict "$APP"
