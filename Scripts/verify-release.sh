#!/usr/bin/env bash
set -euo pipefail

CONFIGURATION="${1:-release}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFO_PLIST="$REPO_ROOT/Packaging/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
APP_DIR="$REPO_ROOT/.build/Wiretap.app"
DMG_PATH="$REPO_ROOT/.build/dist/Wiretap-$VERSION.dmg"
SKIP_TESTS="${WIRETAP_VERIFY_SKIP_TESTS:-0}"
SKIP_BUILD="${WIRETAP_VERIFY_SKIP_BUILD:-0}"
REQUIRE_DMG_SIGNATURE="${WIRETAP_VERIFY_REQUIRE_DMG_SIGNATURE:-0}"
REQUIRE_GATEKEEPER="${WIRETAP_VERIFY_REQUIRE_GATEKEEPER:-0}"
REQUIRE_NOTARIZATION="${WIRETAP_VERIFY_REQUIRE_NOTARIZATION:-0}"
LAUNCH_APP="${WIRETAP_VERIFY_LAUNCH:-0}"
MOUNT_DIR=""
INSTALL_DIR=""

cleanup() {
    if [[ -n "$MOUNT_DIR" && -d "$MOUNT_DIR" ]]; then
        hdiutil detach "$MOUNT_DIR" -quiet || true
        rmdir "$MOUNT_DIR" 2>/dev/null || true
    fi

    if [[ -n "$INSTALL_DIR" && -d "$INSTALL_DIR" ]]; then
        rm -rf "$INSTALL_DIR"
    fi
}
trap cleanup EXIT

cd "$REPO_ROOT"

if [[ "$SKIP_TESTS" != "1" ]]; then
    swift test
fi

if [[ "$SKIP_BUILD" != "1" ]]; then
    "$REPO_ROOT/Scripts/package-dmg.sh" "$CONFIGURATION"
fi

if [[ ! -d "$APP_DIR" ]]; then
    echo "Missing app bundle at $APP_DIR"
    exit 1
fi

if [[ ! -f "$DMG_PATH" ]]; then
    echo "Missing DMG at $DMG_PATH"
    exit 1
fi

plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
hdiutil verify "$DMG_PATH"

if codesign --verify --verbose=2 "$DMG_PATH" >/dev/null 2>&1; then
    codesign --verify --verbose=2 "$DMG_PATH"
elif [[ "$REQUIRE_DMG_SIGNATURE" == "1" ]]; then
    echo "DMG is not signed with a verifiable code signature"
    exit 1
fi

if [[ "$REQUIRE_NOTARIZATION" == "1" ]]; then
    xcrun stapler validate "$DMG_PATH"
fi

MOUNT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wiretap-dmg.XXXXXX")"
hdiutil attach "$DMG_PATH" \
    -nobrowse \
    -readonly \
    -mountpoint "$MOUNT_DIR" \
    -quiet

MOUNTED_APP="$MOUNT_DIR/Wiretap.app"
APPLICATIONS_LINK="$MOUNT_DIR/Applications"

if [[ ! -d "$MOUNTED_APP" ]]; then
    echo "Mounted DMG does not contain Wiretap.app"
    exit 1
fi

if [[ ! -L "$APPLICATIONS_LINK" ]]; then
    echo "Mounted DMG does not contain an Applications symlink"
    exit 1
fi

codesign --verify --deep --strict --verbose=2 "$MOUNTED_APP"
plutil -lint "$MOUNTED_APP/Contents/Info.plist" >/dev/null

if [[ "$REQUIRE_GATEKEEPER" == "1" ]]; then
    spctl --assess --type open --verbose=2 "$DMG_PATH"
    spctl --assess --type execute --verbose=2 "$MOUNTED_APP"
fi

if [[ "$LAUNCH_APP" == "1" ]]; then
    INSTALL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wiretap-install.XXXXXX")"
    cp -R "$MOUNTED_APP" "$INSTALL_DIR/Wiretap.app"
    WIRETAP_SMOKE_SKIP_BUILD=1 \
    WIRETAP_SMOKE_APP_DIR="$INSTALL_DIR/Wiretap.app" \
        "$REPO_ROOT/Scripts/smoke-app.sh" "$CONFIGURATION"
fi

echo "Verified Wiretap $VERSION release artifact at $DMG_PATH"
