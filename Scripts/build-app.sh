#!/usr/bin/env bash
set -euo pipefail

CONFIGURATION="${1:-release}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIGN_IDENTITY="${WIRETAP_SIGN_IDENTITY:--}"

cd "$REPO_ROOT"

swift build -c "$CONFIGURATION"
BUILD_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
APP_DIR="$REPO_ROOT/.build/Wiretap.app"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/Wiretap" "$APP_DIR/Contents/MacOS/Wiretap"
cp "$REPO_ROOT/Packaging/Info.plist" "$APP_DIR/Contents/Info.plist"

if [[ -d "$BUILD_DIR/Wiretap_Wiretap.bundle" ]]; then
    cp -R "$BUILD_DIR/Wiretap_Wiretap.bundle" "$APP_DIR/Contents/Resources/"
fi

cat > "$APP_DIR/Contents/PkgInfo" <<'PKGINFO'
APPL????
PKGINFO

if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --sign - \
        --entitlements "$REPO_ROOT/Packaging/Wiretap.entitlements" \
        "$APP_DIR"
else
    codesign --force --sign "$SIGN_IDENTITY" \
        --options runtime \
        --timestamp \
        --entitlements "$REPO_ROOT/Packaging/Wiretap.entitlements" \
        "$APP_DIR"
fi

echo "Built $APP_DIR"
