# Releasing Wiretap

Public Wiretap releases are built by `.github/workflows/release.yml` when a matching `v*` tag is pushed. The workflow tests the project, signs the app and DMG with Developer ID, notarizes and staples the DMG, verifies the result, and publishes the artifact and its SHA-256 checksum to GitHub Releases.

## One-time setup

The repository must have these GitHub Actions secrets:

- `APPLE_ID`: the Apple ID used for notarization.
- `APPLE_TEAM_ID`: the Apple Developer team identifier.
- `APPLE_APP_SPECIFIC_PASSWORD`: an app-specific password created for notarization.
- `DEVELOPER_ID_APPLICATION_CERTIFICATE_BASE64`: a base64-encoded `.p12` export containing the Developer ID Application certificate and private key.
- `DEVELOPER_ID_APPLICATION_CERTIFICATE_PASSWORD`: the password chosen when exporting the `.p12`.
- `WIRETAP_SIGN_IDENTITY`: the full identity name, such as `Developer ID Application: Example Name (TEAMID)`.

Configure them under **Settings → Secrets and variables → Actions**. Do not commit certificate files or credential values to the repository.

## Publish

1. Update `CFBundleShortVersionString` and `CFBundleVersion` in `Packaging/Info.plist`.
2. Add `.github/release-notes/vX.Y.Z.md`.
3. Confirm `swift test` and `Scripts/verify-release.sh release` pass locally.
4. Commit and push the release preparation to `main`.
5. Create and push the matching version tag:

   ```sh
   git tag -a v0.1.0 -m "Wiretap 0.1.0"
   git push origin v0.1.0
   ```

6. Verify the Release workflow and download the published DMG for a clean-install smoke test.

The tag must exactly match the marketing version in `Packaging/Info.plist`; for example, version `0.1.0` requires tag `v0.1.0`.
