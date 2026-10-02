#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/release"
DIST_DIR="$ROOT_DIR/.build/NudgeAlpha"
APP_DIR="$DIST_DIR/Nudge.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
STAGING_DIR="$DIST_DIR/dmg-staging"
DMG_PATH="$DIST_DIR/Nudge-alpha.dmg"
VERSION="${NUDGE_VERSION:-0.1.0}"
BUILD_NUMBER="${NUDGE_BUILD_NUMBER:-1}"
IDENTITY="${NUDGE_DEVELOPER_ID_APPLICATION:-}"
ENTITLEMENTS="$ROOT_DIR/scripts/Nudge.entitlements"

cd "$ROOT_DIR"
source "$ROOT_DIR/scripts/configure-swift-build.sh"
swift build --disable-sandbox -c release --product Nudge

rm -rf "$APP_DIR" "$STAGING_DIR" "$DMG_PATH"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BUILD_DIR/Nudge" "$MACOS_DIR/Nudge"
bash "$ROOT_DIR/scripts/package-cat-icon.sh" "$RESOURCES_DIR"
if [[ -d "$BUILD_DIR/Nudge_MinderCore.bundle" ]]; then
  cp -R "$BUILD_DIR/Nudge_MinderCore.bundle" "$RESOURCES_DIR/Nudge_MinderCore.bundle"
elif [[ -d "$BUILD_DIR/Minder_MinderCore.bundle" ]]; then
  cp -R "$BUILD_DIR/Minder_MinderCore.bundle" "$RESOURCES_DIR/Minder_MinderCore.bundle"
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>Nudge</string>
  <key>CFBundleIdentifier</key>
  <string>com.kainoanishida.nudge.alpha</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Nudge</string>
  <key>CFBundleIconFile</key>
  <string>NudgeCat</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NudgeReleaseChannel</key>
  <string>alpha</string>
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>Nudge creates calendar events only after you confirm a suggested event.</string>
  <key>NSCalendarsUsageDescription</key>
  <string>Nudge creates calendar events only after you confirm a suggested event.</string>
  <key>NSCalendarsWriteOnlyAccessUsageDescription</key>
  <string>Nudge asks for write-only calendar access to save confirmed event drafts.</string>
  <key>NSContactsUsageDescription</key>
  <string>Nudge uses Contacts locally to show names instead of phone numbers or email handles in imported Messages.</string>
  <key>NSRemindersFullAccessUsageDescription</key>
  <string>Nudge creates reminders only after you confirm a suggested reminder.</string>
</dict>
</plist>
PLIST

python3 "$ROOT_DIR/scripts/configure-managed-build.py" "$CONTENTS_DIR/Info.plist"

chmod +x "$MACOS_DIR/Nudge"

if [[ -n "$IDENTITY" ]]; then
  codesign --force --deep --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP_DIR"
else
  codesign --force --deep --sign - "$APP_DIR"
fi

codesign --verify --deep --strict --verbose=2 "$APP_DIR"
spctl --assess --type execute --verbose "$APP_DIR" || true

mkdir -p "$STAGING_DIR"
cp -R "$APP_DIR" "$STAGING_DIR/Nudge.app"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create -volname "Nudge Alpha" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"

if [[ -n "${NUDGE_NOTARYTOOL_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NUDGE_NOTARYTOOL_PROFILE" --wait
  xcrun stapler staple "$DMG_PATH"
  spctl --assess --type open --verbose "$DMG_PATH"
else
  echo "Skipping notarization. Set NUDGE_NOTARYTOOL_PROFILE to notarize with xcrun notarytool."
fi

echo "Built $APP_DIR"
echo "Packaged $DMG_PATH"
