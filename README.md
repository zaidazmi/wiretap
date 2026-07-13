# Wiretap

Wiretap is a local-first macOS menu bar recorder for system audio plus the current default microphone. It saves one mixed AAC `.m4a` file per recording and keeps an app-managed library for playback, search, rename, reveal, share, export, and delete.

The app is audio-only. It uses ScreenCaptureKit for system-output audio without recording video, and it does not transcribe audio, sync to a cloud service, or install a virtual audio driver.

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

Local builds automatically use the first available Apple Development signing identity so macOS privacy grants survive rebuilds. Machines without a development identity fall back to ad-hoc signing; those builds need privacy access granted again after each rebuild. To select a particular identity or use Developer ID signing:

```sh
WIRETAP_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" Scripts/package-dmg.sh release
```

Set `WIRETAP_SIGN_IDENTITY=-` to force ad-hoc signing.

After switching an existing ad-hoc development build to stable signing, clear its stale Screen Recording entry once, launch the newly built app, grant the upper **Screen Recording** permission, and relaunch Wiretap:

```sh
tccutil reset ScreenCapture dev.zaidazmi.Wiretap
open .build/Wiretap.app
```

The lower **System Audio Recording Only** grant belongs to the older Core Audio tap path and does not satisfy ScreenCaptureKit.

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

- Captures the display-wide system-audio mix through ScreenCaptureKit while excluding Wiretap's own playback.
- Captures the current macOS default input device.
- Uses Apple Sound Isolation for speaker output so the microphone track suppresses far-field speaker playback without lowering the Mac's live or captured system-audio level. VoiceProcessingIO acoustic echo cancellation remains a safety fallback when Sound Isolation cannot start. Headphone and Bluetooth routes keep the raw microphone path to preserve fidelity and handle device format renegotiation.
- Writes source streams losslessly to temporary `.caf` files, then finalizes one 48 kHz stereo AAC `.m4a`.
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

The current suite covers library persistence, metadata migration, missing-file repair, active-recording recovery, search/rename/delete/reveal/export/share flows, Core Audio permission-error mapping, microphone route policy, queued file writes, source alignment, silence padding, duration accuracy, and clipping prevention. The smoke script builds `Wiretap.app`, verifies app metadata and signing, launches the menu bar app, and terminates the launched process.

Hardware capture behavior still needs manual verification across speakers, wired headphones, Bluetooth headphones, default input switching, and sleep/wake.

## License

MIT. See [LICENSE](LICENSE).
