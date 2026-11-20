#!/bin/zsh
# Builds a Developer ID signed, notarized build/MacSweep-<version>.dmg and the Sparkle build/appcast.xml.
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

echo "==> Writing Sparkle appcast"
# Signed with the EdDSA key stored in the keychain under the "macsweep" account (Sparkle's generate_keys).
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
SIGNATURE=$(.build/artifacts/sparkle/Sparkle/bin/sign_update --account macsweep "$DMG")
REPO="https://github.com/karlosmatos/MacSweep"
cat > build/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>MacSweep</title>
    <item>
      <title>$VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$REPO/releases/tag/v$VERSION</sparkle:fullReleaseNotesLink>
      <enclosure url="$REPO/releases/download/v$VERSION/MacSweep-$VERSION.dmg" type="application/octet-stream" $SIGNATURE />
    </item>
  </channel>
</rss>
XML
echo "Upload: gh release create v$VERSION $DMG build/appcast.xml"
