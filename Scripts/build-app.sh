#!/usr/bin/env bash
set -euo pipefail

CONFIGURATION="${1:-release}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIGN_IDENTITY="${WIRETAP_SIGN_IDENTITY:-}"

if [[ -z "$SIGN_IDENTITY" ]]; then
    # TCC grants are tied to the app's code requirement. An ad-hoc signature
    # changes after every rebuild, which makes an enabled Screen Recording row
    # refer to the previous binary. Prefer a stable local Apple Development
    # identity when one is installed; CI and machines without one still fall
    # back to ad-hoc signing.
    SIGN_IDENTITY="$(
        security find-identity -v -p codesigning 2>/dev/null \
            | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
            | head -n 1
    )"
    SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi

cd "$REPO_ROOT"

swift build -c "$CONFIGURATION"
BUILD_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
APP_DIR="$REPO_ROOT/.build/Wiretap.app"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/Wiretap" "$APP_DIR/Contents/MacOS/Wiretap"
cp "$REPO_ROOT/Packaging/Info.plist" "$APP_DIR/Contents/Info.plist"
swift "$REPO_ROOT/Scripts/generate-icon.swift" "$APP_DIR/Contents/Resources/Wiretap.icns"

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
    echo "Signing Wiretap with $SIGN_IDENTITY"
    SIGNING_OPTIONS=(
        --force
        --sign "$SIGN_IDENTITY"
        --options runtime
        --entitlements "$REPO_ROOT/Packaging/Wiretap.entitlements"
    )
    # A trusted timestamp is required for Developer ID distribution, but local
    # Apple Development identities are not timestamped. Asking codesign to
    # timestamp a development signature can leave the rebuilt bundle invalid.
    if [[ "$SIGN_IDENTITY" == Developer\ ID\ Application:* ]]; then
        SIGNING_OPTIONS+=(--timestamp)
    fi
    codesign "${SIGNING_OPTIONS[@]}" "$APP_DIR"
fi

test -s "$APP_DIR/Contents/Resources/Wiretap.icns"

echo "Built $APP_DIR"

# Finder and Launch Services cache bundle metadata by identifier/version. Force
# the freshly generated development bundle to be registered so icon changes are
# visible immediately even though its marketing version has not changed.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$APP_DIR" >/dev/null 2>&1 || true
fi
touch "$APP_DIR"
