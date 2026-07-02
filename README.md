# Wiretap

Wiretap is a local-first macOS menu bar recorder for system audio plus the current default microphone. It saves one mixed AAC `.m4a` file per recording and keeps an app-managed library for playback, search, rename, reveal, share, export, and delete.

The app is audio-only. It uses Core Audio process taps for system output capture rather than screen recording APIs, and it does not record video, transcribe audio, sync to a cloud service, or install a virtual audio driver.

## Requirements

- macOS 15 or newer
- Swift 6.2 toolchain
- Microphone permission
- Audio Capture permission when macOS prompts for system-audio capture

## Build And Run

```sh
swift run Wiretap
```

For an installable local app bundle:

```sh
Scripts/build-app.sh debug
open .build/Wiretap.app
```

For a DMG:

```sh
Scripts/package-dmg.sh debug
open .build/dist
```

By default, local builds are ad-hoc signed. To use Developer ID signing:

```sh
WIRETAP_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" Scripts/package-dmg.sh release
```

To notarize the DMG, also set `WIRETAP_NOTARIZE=1`, `APPLE_ID`, `APPLE_TEAM_ID`, and `APPLE_APP_SPECIFIC_PASSWORD`.

To verify a built release artifact without rebuilding it:

```sh
WIRETAP_VERIFY_SKIP_TESTS=1 WIRETAP_VERIFY_SKIP_BUILD=1 Scripts/verify-release.sh release
```

For notarized release candidates, add `WIRETAP_VERIFY_REQUIRE_NOTARIZATION=1`. Gatekeeper and launch checks are opt-in with `WIRETAP_VERIFY_REQUIRE_GATEKEEPER=1` and `WIRETAP_VERIFY_LAUNCH=1`.

## GitHub Releases

CI and release jobs run on GitHub's `macos-26` runner so Swift 6.2 is available.

Pushing a `v<CFBundleShortVersionString>` tag runs the release workflow, builds a release DMG, signs it with Developer ID, notarizes it, staples it, and uploads it to GitHub Releases.

The release workflow also mounts and verifies the DMG layout, app signature, app metadata, DMG checksum, and stapled notarization ticket before publishing.

Required repository secrets:

- `APPLE_APP_SPECIFIC_PASSWORD`
- `APPLE_ID`
- `APPLE_TEAM_ID`
- `DEVELOPER_ID_APPLICATION_CERTIFICATE_BASE64`
- `DEVELOPER_ID_APPLICATION_CERTIFICATE_PASSWORD`
- `WIRETAP_SIGN_IDENTITY`

## Recording Behavior

- Captures all system output audio except Wiretap itself when Core Audio can resolve the current process.
- Captures the current macOS default input device.
- Writes source streams to temporary `.m4a` files, then finalizes one 48 kHz stereo AAC `.m4a`.
- Applies source alignment, silence padding, and peak limiting during offline mixing without pitch-shifting captured audio.
- Checks available disk space before starting a recording.
- Stores finished recordings under `Application Support/<bundle-id>/Recordings`.
- Stores interrupted source files under `Application Support/<bundle-id>/Recovery` when needed.
- Generates the packaged app icon during `Scripts/build-app.sh` so release artifacts do not rely on checked-in binary image assets.

## Recovery

Wiretap saves an active recording marker before capture starts. If the app quits, the Mac sleeps, the session changes, or the process does not shut down cleanly, the next launch repairs the library item and preserves any recoverable source files for review.

## Tests

```sh
swift test
```

For an app-bundle launch smoke:

```sh
Scripts/smoke-app.sh debug
```

The current suite covers library persistence, metadata migration, missing-file repair, active-recording recovery, search/rename/delete/reveal/export/share flows, Core Audio permission-error mapping, queued file writes, source alignment, silence padding, duration accuracy, and clipping prevention. The smoke script builds `Wiretap.app`, verifies app metadata and signing, launches the menu bar app, and terminates the launched process.

Hardware capture behavior still needs manual verification across speakers, wired headphones, Bluetooth headphones, default input switching, and sleep/wake.

## License

MIT. See [LICENSE](LICENSE).
