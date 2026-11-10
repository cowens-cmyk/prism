#!/bin/bash
# Builds Prism for the booth Mac: Release, Developer ID signed,
# notarized when the "notarization-profile" keychain profile exists, as a DMG
# in build/dist. Without notarization the booth Mac opens it with
# right-click › Open the first time.
set -euo pipefail

export PATH="/opt/homebrew/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${DEVELOPER_ID_IDENTITY:-Developer ID Application: Hope Church JC (TCAQTA64TB)}"
PROFILE="notarization-profile"
DIST="$ROOT/build/dist"
# Outside ~/Desktop: iCloud's metadata on Desktop files breaks codesign.
DERIVED="${TMPDIR:-/tmp}/prism-release"
APP="$DERIVED/Build/Products/Release/Prism.app"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD)"

echo "==> Testing LightsCore"
swift test --package-path "$ROOT/Packages/LightsCore" --scratch-path "$DERIVED/core" 2>&1 | tail -1

echo "==> Building Release $BUILD_NUMBER"
xcodegen generate --spec "$ROOT/project.yml" --project "$ROOT" | tail -1
xcodebuild -project "$ROOT/Prism.xcodeproj" -scheme Prism -configuration Release \
  -derivedDataPath "$DERIVED" -destination 'generic/platform=macOS' \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" build | tail -2

echo "==> Signing"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --deep "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
rm -rf "$DIST" && mkdir -p "$DIST"

if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "==> Notarizing"
  ditto -c -k --keepParent "$APP" "$DIST/app.zip"
  xcrun notarytool submit "$DIST/app.zip" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$APP"
  rm "$DIST/app.zip"
else
  echo "==> No \"$PROFILE\" keychain profile: skipping notarization"
fi

echo "==> Building the DMG"
STAGE="$DIST/stage"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Prism" -srcfolder "$STAGE" -ov -format UDZO "$DIST/Prism-$VERSION.dmg" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DIST/Prism-$VERSION.dmg"
echo "==> $DIST/Prism-$VERSION.dmg"
