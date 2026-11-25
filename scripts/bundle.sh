#!/bin/zsh
# Builds and signs build/MacSweep.app. Used by build.sh (local install) and release.sh (DMG).
#   --release   secure timestamp in the signature (needed for notarization); fails without Developer ID
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/MacSweep.app"
VERSION=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)
BUILD=$(git rev-list --count HEAD)

# Constant values of App Intents types, read by appintentsmetadataprocessor below (Xcode does both for app targets).
PROTOCOLS=$(mktemp -t macsweep-protocols)
echo '["AppIntent","AppShortcutsProvider","AppEntity","TransientEntity","AppEnum","EntityQuery","DynamicOptionsProvider"]' >"$PROTOCOLS"
swift build -c release -Xswiftc -emit-const-values \
    -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file -Xswiftc -Xfrontend -Xswiftc "$PROTOCOLS"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MacSweep "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns scripts/disk-cleanup.sh "$APP/Contents/Resources/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
# Shortcuts actions: the system only offers App Intents listed in Contents/Resources/Metadata.appintents.
LISTS=$(mktemp -d -t macsweep-intents)
ls "$PWD"/Sources/MacSweep/*.swift >"$LISTS/sources"
find .build -name '*.swiftconstvalues' \( -path '*/Release/MacSweep-p.build/*' -o -path '*/release/MacSweep.build/*' \) >"$LISTS/constvalues"
[[ -s "$LISTS/constvalues" ]] || { echo "No .swiftconstvalues from the release build." >&2; exit 1; }
xcrun appintentsmetadataprocessor --quiet-warnings --output "$APP/Contents/Resources" \
    --toolchain-dir "$(dirname "$(dirname "$(dirname "$(xcrun --find swift)")")")" --module-name MacSweep \
    --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" --xcode-version "$(xcodebuild -version | awk '/Build version/ {print $3}')" \
    --platform-family macOS --deployment-target 14.0 --target-triple "$(uname -m)-apple-macos14.0" \
    --source-file-list "$LISTS/sources" --swift-const-vals-list "$LISTS/constvalues" --binary-file .build/release/MacSweep 2>/dev/null
[[ -d "$APP/Contents/Resources/Metadata.appintents" ]] || { echo "App Intents metadata was not generated." >&2; exit 1; }
rm -rf "$PROTOCOLS" "$LISTS"
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
