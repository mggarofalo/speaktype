# Release Process

SpeakType releases are now built and notarized **locally**, then uploaded to GitHub using GitHub CLI.

This approach provides:
- ✅ **Faster releases** (2-5 min vs 30+ min timeout)
- ✅ **Better debugging** (see errors immediately)
- ✅ **No CI complexity** (all work done on your Mac)
- ✅ **Secure credentials** (stored in macOS Keychain)

## Release Criteria
Use your judgment, but a release is usually warranted when one or more are true:
- A user-visible feature or UX improvement lands
- A bugfix affects multiple users or a core flow
- Performance or stability improvements are measurable or noticeable

## Prerequisites

### One-Time Setup

**1. Code Signing Certificate**

You must have a valid **Developer ID Application** certificate installed.

Verify it's installed:
```bash
security find-identity -v -p codesigning
# Should show: "Developer ID Application: ..."
```

If not installed, see [Apple's documentation](https://developer.apple.com/support/code-signing/) on obtaining a Developer ID certificate.

**2. App-Specific Password**

You'll need an app-specific password from your Apple account:

1. Go to [appleid.apple.com](https://appleid.apple.com)
2. Sign in with `mail2048labs@gmail.com`
3. Security → App-Specific Passwords
4. Generate new password (or use existing notarization password)

**Note:** The build script will prompt for this password on first run and store it securely in your macOS Keychain.

**3. GitHub CLI** (optional, for uploading releases)

```bash
brew install gh
gh auth login
```

## Creating a Release

### Step 1: Bump Version

Use the release script to update version numbers and changelog:

```bash
scripts/release.sh 1.0.7
```

This automatically:
- Updates `MARKETING_VERSION` in Xcode project
- Increments `CURRENT_PROJECT_VERSION` (build number)
- Updates `CHANGELOG.md` with release date
- Creates a commit and git tag

Then push:
```bash
git push origin HEAD
git push origin v1.0.7
```

### Step 2: Build and Notarize

Run the build script to create a signed, notarized DMG:

```bash
./scripts/build-and-notarize.sh v1.0.7
```

This script will:
1. ✅ Build the Release configuration
2. ✅ Code-sign the app with Developer ID
3. ✅ Verify the signature
4. ✅ Create the DMG installer
5. ✅ Sign the DMG
6. ✅ Submit to Apple for notarization (**2-5 minutes**)
7. ✅ Wait for Apple's response
8. ✅ Staple the notarization ticket
9. ✅ Verify Gatekeeper acceptance

Output: `SpeakType-1.0.7.dmg` (ready to distribute)

### Step 3: Create GitHub Release

Upload the notarized DMG to GitHub:

```bash
gh release create v1.0.7 SpeakType-1.0.7.dmg --generate-notes
```

Done! 🎉

## Quick Reference

**First release ever:**
```bash
./scripts/build-and-notarize.sh v1.0.7
# (will prompt for app-specific password on first run)
gh release create v1.0.7 SpeakType-1.0.7.dmg --generate-notes
```

**Subsequent releases:**
```bash
scripts/release.sh 1.0.8
git push origin HEAD && git push origin v1.0.8
./scripts/build-and-notarize.sh v1.0.8
gh release create v1.0.8 SpeakType-1.0.8.dmg --generate-notes
```

## Verification

After the release, verify on a **different Mac**:

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

### Authentication Error (401)
```
Error: HTTP status code: 401. Unable to authenticate.
```

**Fix:** Regenerate your app-specific password and re-run the keychain setup:
```bash
xcrun notarytool store-credentials "AC_PASSWORD" \
  --apple-id "mail2048labs@gmail.com" \
  --team-id "PCV4UMSRZX" \
  --password "NEW_PASSWORD_HERE"
```

### Notarization Rejected

Check the submission logs:
```bash
xcrun notarytool history --keychain-profile "AC_PASSWORD"
# Get the submission ID, then:
xcrun notarytool log <submission-id> --keychain-profile "AC_PASSWORD"
```

Common issues:
- Missing Hardened Runtime entitlement
- Invalid code signature
- Unsigned frameworks/libraries

See [CODESIGNING.md](CODESIGNING.md) for detailed troubleshooting.

### Build Errors

If Xcode build fails:
1. Clean build folder: `xcodebuild clean -scheme speaktype`
2. Verify certificate is valid: `security find-identity -v -p codesigning`
3. Check Xcode version: `xcodebuild -version`

## Notes

- **DMG files are NOT committed to git** - they're large and shouldn't be version-controlled
- **GitHub Actions workflow is disabled** - all release work happens locally
- **Notarization typically takes 2-5 minutes** - Apple's servers process the app
- **The DMG is stapled** - notarization ticket embedded, works offline
