#!/usr/bin/env bash
#
# Builds a downloadable Grove: dist/Grove.dmg (drag to Applications) and
# dist/Grove.zip (for Homebrew), from the version in ./VERSION.
#
#   ./scripts/release.sh
#
# Unsigned by default, which works with no Apple Developer account: macOS
# asks the user to approve it once in System Settings → Privacy & Security →
# Open Anyway. Signed and notarized when these are set, which removes that
# step entirely:
#
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE="grove"     # from: xcrun notarytool store-credentials grove
#
# Google sign-in needs GROVE_GOOGLE_CLIENT_ID (or GroveApp/google-client-id.txt),
# exactly as for a local build.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
VERSION="$(tr -d '[:space:]' < VERSION)"
DIST="$ROOT/dist"
APP="$ROOT/GroveApp/build/Grove.app"

step() { printf '\n==> %s\n' "$*"; }

step "Grove $VERSION"
./scripts/sync-version.sh --check

step "Building the app"
( cd GroveApp && ./scripts/bundle.sh release )

rm -rf "$DIST"
mkdir -p "$DIST"

if [ -n "${DEVELOPER_ID:-}" ]; then
    step "Signing with $DEVELOPER_ID"
    # Hardened runtime is what notarization requires; the entitlements put
    # back the two things it would otherwise forbid Grove: the microphone
    # and the calendar.
    codesign --force --deep --options runtime --timestamp \
        --entitlements GroveApp/Resources/Grove.entitlements \
        --sign "$DEVELOPER_ID" "$APP"
    codesign --verify --strict --verbose=2 "$APP"
else
    step "No DEVELOPER_ID set — building an unsigned release"
fi

step "Packaging Grove.zip"
# ditto keeps the bundle's metadata and signature intact; zip does not.
ditto -c -k --keepParent "$APP" "$DIST/Grove.zip"

if [ -n "${DEVELOPER_ID:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
    step "Notarizing (a few minutes)"
    xcrun notarytool submit "$DIST/Grove.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    # Re-zip so the archive carries the stapled ticket.
    rm "$DIST/Grove.zip"
    ditto -c -k --keepParent "$APP" "$DIST/Grove.zip"
fi

step "Packaging Grove.dmg"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
# The familiar layout: the app, and an arrow-less shortcut to Applications to
# drag it onto.
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Grove" -srcfolder "$STAGING" -ov -format UDZO "$DIST/Grove.dmg" >/dev/null
rm -rf "$STAGING"

if [ -n "${DEVELOPER_ID:-}" ]; then
    codesign --force --timestamp --sign "$DEVELOPER_ID" "$DIST/Grove.dmg"
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        xcrun notarytool submit "$DIST/Grove.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DIST/Grove.dmg"
    fi
fi

# Versioned copies too, so old releases stay distinguishable once downloaded.
cp "$DIST/Grove.dmg" "$DIST/Grove-$VERSION.dmg"
cp "$DIST/Grove.zip" "$DIST/Grove-$VERSION.zip"

step "Done"
echo "  $DIST/Grove.dmg"
echo "  $DIST/Grove.zip"
echo "  zip sha256: $(shasum -a 256 "$DIST/Grove.zip" | cut -d' ' -f1)   (for the Homebrew cask)"
