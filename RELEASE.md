# Release Process

This repository ships releases by pushing a Git tag that starts with `v` (e.g., `v1.0.6`).
The GitHub Actions workflow builds a DMG and attaches it to the GitHub Release.

## Release Criteria
Use your judgment, but a release is usually warranted when one or more are true:
- A user-visible feature or UX improvement lands
- A bugfix affects multiple users or a core flow
- Performance or stability improvements are measurable or noticeable

## Prerequisites

### Code Signing Setup
The app is **code-signed and notarized** with Apple Developer ID to prevent macOS Gatekeeper warnings.

**First-time setup** (one-time only):
1. Follow the complete setup guide in [CODESIGNING.md](CODESIGNING.md)
2. Configure GitHub Secrets with your certificates and credentials

**Required GitHub Secrets:**
- `DEVELOPER_ID_APPLICATION_CERT` - Base64-encoded .p12 certificate
- `DEVELOPER_ID_APPLICATION_CERT_PASSWORD` - Certificate password
- `APPLE_TEAM_ID` - Your Apple Developer Team ID
- `NOTARIZATION_APPLE_ID` - Your Apple ID email
- `NOTARIZATION_PASSWORD` - App-specific password

Without these secrets, the release will fail during the signing step.

## Checklist (Manual)
1. Update `CHANGELOG.md`:
   - Move items from `Unreleased` into a new version section.
2. Bump versions in `speaktype.xcodeproj/project.pbxproj`:
   - `MARKETING_VERSION` (public version, e.g., `1.0.6`)
   - `CURRENT_PROJECT_VERSION` (build number, e.g., `2`)
3. Commit changes.
4. Tag and push the release tag:
   - `git tag v1.0.6`
   - `git push origin v1.0.6`
5. Confirm GitHub Actions completes and the DMG appears in the release.

## One-Command Release (script)
If you prefer automation, use the script below:

```bash
scripts/release.sh 1.0.6
```

This will:
- Update version numbers
- Update `CHANGELOG.md`
- Create a commit
- Create a tag

You still need to push the tag and commit:

```bash
git push origin HEAD
git push origin v1.0.6
```

## What Happens During Release

When you push a tag, GitHub Actions automatically:
1. ✅ Imports your Developer ID certificate
2. ✅ Builds the app with Release configuration
3. ✅ Code-signs with Developer ID Application
4. ✅ Verifies the signature
5. ✅ Creates the DMG installer
6. ✅ Submits to Apple for notarization (2-5 minutes)
7. ✅ Staples the notarization ticket to the DMG
8. ✅ Verifies Gatekeeper will accept the app
9. ✅ Uploads the signed DMG to GitHub Releases

## Verification

After the release completes, verify on a **different Mac**:

```bash
# Download and open the DMG
# Drag SpeakType.app to Applications
# Double-click to open - should NOT show Gatekeeper warning

# Verify signature
codesign -dv --verbose=4 /Applications/SpeakType.app

# Verify notarization
spctl -a -vv /Applications/SpeakType.app
# Should show: accepted, source=Notarized Developer ID
```

## Troubleshooting

If the release fails during signing/notarization:
1. Check GitHub Actions logs for error details
2. Verify all secrets are configured correctly
3. See [CODESIGNING.md](CODESIGNING.md) troubleshooting section
4. Ensure your Developer ID certificate is valid

