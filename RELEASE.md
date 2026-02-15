# Release Process

SpeakType releases are **fully automated** with a single command. The script handles everything: version bumping, building, signing, notarization, and uploading.

## Release Criteria
Use your judgment, but a release is usually warranted when:
- A user-visible feature or UX improvement lands
- A bugfix affects multiple users or a core flow
- Performance or stability improvements are measurable

## Prerequisites

### One-Time Setup

**1. Code Signing Certificate**

Verify you have a Developer ID Application certificate:
```bash
security find-identity -v -p codesigning
# Should show: "Developer ID Application: ..."
```

**2. App-Specific Password**

Get from [appleid.apple.com](https://appleid.apple.com) → Security → App-Specific Passwords

**Note:** The release script will prompt for this on first run and store it in Keychain.

**3. GitHub CLI** (optional)

```bash
brew install gh
gh auth login
```

---

## Creating a Release

### Auto-Bump Patch Version (Recommended)

```bash
./scripts/release.sh
```

**What happens:**

1. ✅ **Checks for uncommitted changes** - Script fails if you have any uncommitted work
2. ✅ **Auto-bumps patch version** (e.g., 1.0.14 → 1.0.15)
3. ✅ **Updates version in Xcode project** - MARKETING_VERSION and CURRENT_PROJECT_VERSION
4. ✅ **Updates CHANGELOG** with release date
5. ✅ **Commits changes locally** - Creates commit and git tag (not pushed yet!)
6. ✅ **Builds and signs the app** - Release configuration with Developer ID
7. ✅ **Creates and signs DMG**
8. ✅ **Submits to Apple for notarization** (~2-5 minutes)
9. ✅ **Staples the notarization ticket**
10. ✅ **Prompts: Push to GitHub?** - Only after successful build
11. ✅ **Prompts: Upload release?** - Only if you pushed

**Total time: ~6-8 minutes**

### Specify Version Manually

```bash
./scripts/release.sh 2.0.0
```

Same workflow, but uses your specified version.

---

## What You'll Be Asked

The script prompts you at key decision points:

1. **🔼 Push v1.0.15 to GitHub? (y/n)**
   - Asked AFTER successful build/notarization
   - If you say `n`, the script exits and tells you how to undo the local commit
   - Safe to say `n` to test the DMG first

2. **📦 Upload DMG to GitHub releases? (y/n)**
   - Only asked if you said `y` to push
   - Uses GitHub CLI to create the release
   - You can always upload manually later with: `gh release create v1.0.15 SpeakType-1.0.15.dmg --generate-notes`

---

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
