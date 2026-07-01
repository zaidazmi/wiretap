#!/usr/bin/env bash
set -euo pipefail

CONFIGURATION="${1:-debug}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$REPO_ROOT/.build/Wiretap.app"
EXECUTABLE_PATH="$APP_DIR/Contents/MacOS/Wiretap"
SKIP_BUILD="${WIRETAP_SMOKE_SKIP_BUILD:-0}"
LAUNCHED_PID=""

find_wiretap_pids() {
    local pids
    local pid
    local command

    pids="$(pgrep -x Wiretap 2>/dev/null || true)"
    while read -r pid; do
        [[ -n "$pid" ]] || continue

        command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
        if [[ "$command" == "$EXECUTABLE_PATH"* ]]; then
            echo "$pid"
        fi
    done <<< "$pids"
}

highest_pid() {
    awk 'BEGIN { max = 0 } { if ($1 > max) max = $1 } END { print max }'
}

cleanup() {
    if [[ -n "$LAUNCHED_PID" ]] && kill -0 "$LAUNCHED_PID" >/dev/null 2>&1; then
        kill "$LAUNCHED_PID" >/dev/null 2>&1 || true

        for _ in {1..20}; do
            if ! kill -0 "$LAUNCHED_PID" >/dev/null 2>&1; then
                return
            fi
            sleep 0.1
        done

        kill -9 "$LAUNCHED_PID" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

cd "$REPO_ROOT"

if [[ "$SKIP_BUILD" != "1" ]]; then
    "$REPO_ROOT/Scripts/build-app.sh" "$CONFIGURATION"
fi

if [[ ! -d "$APP_DIR" ]]; then
    echo "Missing app bundle at $APP_DIR"
    exit 1
fi

if [[ ! -x "$EXECUTABLE_PATH" ]]; then
    echo "Missing executable at $EXECUTABLE_PATH"
    exit 1
fi

plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_DIR/Contents/Info.plist")"
if [[ "$BUNDLE_ID" != "dev.zaidazmi.Wiretap" ]]; then
    echo "Unexpected bundle identifier: $BUNDLE_ID"
    exit 1
fi

LS_UI_ELEMENT="$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$APP_DIR/Contents/Info.plist")"
if [[ "$LS_UI_ELEMENT" != "true" ]]; then
    echo "Wiretap app bundle is not configured as a menu bar app"
    exit 1
fi

BEFORE_HIGHEST_PID="$(find_wiretap_pids | highest_pid)"
open -Fn -gj "$APP_DIR"

for _ in {1..100}; do
    CANDIDATE_PID="$(find_wiretap_pids | highest_pid)"
    if [[ "$CANDIDATE_PID" -gt "$BEFORE_HIGHEST_PID" ]]; then
        LAUNCHED_PID="$CANDIDATE_PID"
        break
    fi
    sleep 0.1
done

if [[ -z "$LAUNCHED_PID" ]]; then
    echo "Wiretap did not launch from $APP_DIR"
    exit 1
fi

if ! kill -0 "$LAUNCHED_PID" >/dev/null 2>&1; then
    echo "Wiretap process $LAUNCHED_PID exited before smoke verification"
    exit 1
fi

echo "Smoke verified Wiretap.app launch as PID $LAUNCHED_PID"
