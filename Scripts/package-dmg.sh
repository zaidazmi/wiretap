#!/usr/bin/env bash
set -euo pipefail

CONFIGURATION="${1:-release}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$REPO_ROOT/.build/dist"
STAGING_DIR="$DIST_DIR/dmg-root"
APP_DIR="$REPO_ROOT/.build/Wiretap.app"
INFO_PLIST="$REPO_ROOT/Packaging/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
DMG_PATH="$DIST_DIR/Wiretap-$VERSION.dmg"
VOLUME_NAME="Wiretap $VERSION"
SIGN_IDENTITY="${WIRETAP_SIGN_IDENTITY:-}"
NOTARIZE="${WIRETAP_NOTARIZE:-0}"

cd "$REPO_ROOT"

"$REPO_ROOT/Scripts/build-app.sh" "$CONFIGURATION"

rm -rf "$DIST_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_DIR" "$STAGING_DIR/Wiretap.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

hdiutil verify "$DMG_PATH"

if [[ -n "$SIGN_IDENTITY" && "$SIGN_IDENTITY" != "-" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"
fi

if [[ "$NOTARIZE" == "1" ]]; then
    : "${APPLE_ID:?Set APPLE_ID to notarize the DMG}"
    : "${APPLE_TEAM_ID:?Set APPLE_TEAM_ID to notarize the DMG}"
    : "${APPLE_APP_SPECIFIC_PASSWORD:?Set APPLE_APP_SPECIFIC_PASSWORD to notarize the DMG}"

    xcrun notarytool submit "$DMG_PATH" \
        --apple-id "$APPLE_ID" \
        --team-id "$APPLE_TEAM_ID" \
        --password "$APPLE_APP_SPECIFIC_PASSWORD" \
        --wait
    xcrun stapler staple "$DMG_PATH"
fi

echo "Built $DMG_PATH"
