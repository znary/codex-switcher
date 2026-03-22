#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/multi-codex-limit-viewer.xcodeproj"
SCHEME="${SCHEME:-multi-codex-limit-viewer}"
CONFIGURATION="${CONFIGURATION:-Release}"
TEAM_ID="${TEAM_ID:-24D7733HKN}"
APP_NAME="${APP_NAME:-multi-codex-limit-viewer}"
DISPLAY_NAME="${DISPLAY_NAME:-Codex Switcher}"
BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/build/direct}"
ARCHIVE_PATH="$BUILD_ROOT/$DISPLAY_NAME.xcarchive"
EXPORT_PATH="$BUILD_ROOT/export"
DMG_ROOT="$BUILD_ROOT/dmg-root"
DMG_PATH="$BUILD_ROOT/${DISPLAY_NAME// /-}.dmg"
EXPORT_OPTIONS_PLIST="$BUILD_ROOT/ExportOptions.plist"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
DMG_SIGN_IDENTITY="${DMG_SIGN_IDENTITY:-}"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

resolve_dmg_sign_identity() {
  if [[ -n "$DMG_SIGN_IDENTITY" ]]; then
    return
  fi

  DMG_SIGN_IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | awk -F'"' '/Developer ID Application/ { print $2; exit }'
  )"

  if [[ -z "$DMG_SIGN_IDENTITY" ]]; then
    echo "Could not find a Developer ID Application certificate in the keychain." >&2
    echo "Set DMG_SIGN_IDENTITY to the full certificate name and run again." >&2
    exit 1
  fi
}

require_command xcodebuild
require_command hdiutil
require_command codesign
require_command security
require_command spctl

rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT"

cat >"$EXPORT_OPTIONS_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>destination</key>
  <string>export</string>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>teamID</key>
  <string>$TEAM_ID</string>
</dict>
</plist>
PLIST

echo "==> Archiving app"
xcodebuild archive \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -archivePath "$ARCHIVE_PATH"

echo "==> Exporting Developer ID app"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"

APP_PATH="$EXPORT_PATH/$APP_NAME.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Expected app bundle was not found: $APP_PATH" >&2
  exit 1
fi

resolve_dmg_sign_identity

echo "==> Verifying exported app signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl -a -vv -t exec "$APP_PATH"

echo "==> Creating DMG staging folder"
rm -rf "$DMG_ROOT"
mkdir -p "$DMG_ROOT"
cp -R "$APP_PATH" "$DMG_ROOT/"
ln -s /Applications "$DMG_ROOT/Applications"

echo "==> Building DMG"
rm -f "$DMG_PATH"
hdiutil create \
  -volname "$DISPLAY_NAME" \
  -srcfolder "$DMG_ROOT" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "==> Signing DMG with: $DMG_SIGN_IDENTITY"
codesign --force --sign "$DMG_SIGN_IDENTITY" --timestamp "$DMG_PATH"

if [[ -n "$NOTARY_PROFILE" ]]; then
  require_command xcrun

  echo "==> Submitting DMG for notarization"
  xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

  echo "==> Stapling notarization ticket to DMG"
  xcrun stapler staple "$DMG_PATH"
else
  cat <<EOF
==> Skipped notarization because NOTARY_PROFILE is empty.
To avoid Gatekeeper's unsafe warning on user machines, notarization is required.
Create a profile first:
  xcrun notarytool store-credentials "codex-notary" --apple-id "<APPLE_ID>" --team-id "$TEAM_ID" --password "<APP_SPECIFIC_PASSWORD>"
Then rerun:
  NOTARY_PROFILE=codex-notary ./scripts/package_direct_dmg.sh
EOF
fi

echo "==> Verifying DMG"
spctl -a -vv -t open "$DMG_PATH"

cat <<EOF

Done.
App bundle: $APP_PATH
DMG: $DMG_PATH
EOF
