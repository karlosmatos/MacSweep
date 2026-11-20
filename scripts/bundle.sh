#!/bin/zsh
# Builds and signs build/MacSweep.app. Used by build.sh (local install) and release.sh (DMG).
#   --release   secure timestamp in the signature (needed for notarization); fails without Developer ID
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/MacSweep.app"
VERSION=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)
BUILD=$(git rev-list --count HEAD)

swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MacSweep "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns scripts/disk-cleanup.sh "$APP/Contents/Resources/"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION:-1.0}" -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"

# Same Developer ID identity for local and release builds, so privacy grants (Full Disk Access) survive updates.
# Picked by hash: the keychain can hold several certificates with the same name.
IDENTITY=$(scripts/identity.sh)
if [[ "${1:-}" == "--release" ]]; then
    [[ -n "$IDENTITY" ]] || { echo "No Developer ID Application certificate in the keychain." >&2; exit 1; }
    TIMESTAMP=--timestamp
else
    IDENTITY=${IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')}
    TIMESTAMP=--timestamp=none
fi

# Sparkle, minus the XPC services that only sandboxed apps need. Nested code is signed before the app.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
mkdir -p "$APP/Contents/Frameworks"
ditto .build/release/Sparkle.framework "$SPARKLE"
rm -rf "$SPARKLE/Versions/B/XPCServices"
for nested in "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app" "$SPARKLE"; do
    codesign --force --options runtime $TIMESTAMP --sign "${IDENTITY:--}" "$nested"
done
codesign --force --options runtime $TIMESTAMP --entitlements Resources/MacSweep.entitlements --sign "${IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP ${VERSION:-1.0} ($BUILD)"
