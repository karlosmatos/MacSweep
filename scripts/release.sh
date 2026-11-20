#!/bin/zsh
# Builds a Developer ID signed, notarized build/MacSweep-<version>.dmg.
# Tag first (git tag v1.1) to set the version. Needs a notarytool keychain profile:
#   xcrun notarytool store-credentials AC_NOTARY
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-AC_NOTARY}"
scripts/bundle.sh --release
APP="build/MacSweep.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")

echo "==> Notarizing app"
ditto -c -k --keepParent "$APP" build/MacSweep.zip
xcrun notarytool submit build/MacSweep.zip --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm build/MacSweep.zip

echo "==> Creating DMG"
DMG="build/MacSweep-$VERSION.dmg"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname MacSweep -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
codesign --force --timestamp --sign "$(scripts/identity.sh)" "$DMG"

echo "==> Notarizing DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"
echo "$DMG"
