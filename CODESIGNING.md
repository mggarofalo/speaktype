# Code Signing and Notarization Guide

This guide explains how to set up Apple Developer ID code signing and notarization for SpeakType, so the app can be distributed without macOS Gatekeeper warnings.

## Why This is Needed

Starting with macOS 10.15 (Catalina), all apps distributed outside the Mac App Store must be:
1. **Code-signed** with a Developer ID Application certificate
2. **Notarized** by Apple (automated malware scan)
3. **Stapled** with the notarization ticket

Without this, users see: *"Apple could not verify 'SpeakType' is free of malware..."*

## Prerequisites

- **Apple Developer Program** subscription ($99/year)
- **macOS machine** with Xcode and Keychain Access
- **Admin access** to the GitHub repository

## Step 1: Generate Developer ID Certificate

### 1.1 Create Certificate Signing Request (CSR)

On your Mac:

1. Open **Keychain Access** (Applications → Utilities)
2. Menu: **Keychain Access → Certificate Assistant → Request a Certificate from a Certificate Authority**
3. Fill in:
   - **User Email Address**: Your Apple ID email
   - **Common Name**: Your name or company name
   - **Request is**: Saved to disk
4. Click **Continue** and save the `CertificateSigningRequest.certSigningRequest` file

### 1.2 Generate Certificate on Apple Developer Portal

1. Go to https://developer.apple.com/account/resources/certificates/list
2. Click **+** to create a new certificate
3. Select **Developer ID Application** (under "Software")
4. Click **Continue**
5. Upload the CSR file you created
6. Click **Continue** → **Download**
7. Double-click the downloaded certificate to install it in Keychain

### 1.3 Export Certificate as .p12

1. Open **Keychain Access**
2. Select **login** keychain and **My Certificates** category
3. Find your **Developer ID Application** certificate (should show your name)
4. **Right-click** → **Export "Developer ID Application: ..."**
5. Save as: `DeveloperIDApplication.p12`
6. Enter a **strong password** (you'll need this for GitHub Secrets)
7. Enter your Mac password to allow the export

### 1.4 Encode Certificate as Base64

```bash
base64 -i DeveloperIDApplication.p12 | pbcopy
```

This copies the base64-encoded certificate to your clipboard.

## Step 2: Create App-Specific Password

For notarization, you need an app-specific password:

1. Go to https://appleid.apple.com/account/manage
2. Sign in with your Apple ID
3. In **Security** section, under **App-Specific Passwords**, click **Generate Password**
4. Label: `SpeakType Notarization`
5. Copy the generated password (format: `xxxx-xxxx-xxxx-xxxx`)

## Step 3: Find Your Team ID

1. Go to https://developer.apple.com/account
2. Click **Membership** in the sidebar
3. Your **Team ID** is shown (format: `ABC1234DEF`)

## Step 4: Configure GitHub Secrets

1. Go to your repository: https://github.com/karansinghgit/speaktype
2. Click **Settings** → **Secrets and variables** → **Actions**
3. Click **New repository secret** and add each of these:

| Secret Name | Value |
|-------------|-------|
| `DEVELOPER_ID_APPLICATION_CERT` | Paste the base64-encoded .p12 from Step 1.4 |
| `DEVELOPER_ID_APPLICATION_CERT_PASSWORD` | The password you set when exporting the .p12 |
| `APPLE_TEAM_ID` | Your Team ID from Step 3 |
| `NOTARIZATION_APPLE_ID` | Your Apple ID email |
| `NOTARIZATION_PASSWORD` | The app-specific password from Step 2 |

## Step 5: Verify Setup

After the secrets are configured, the next release you create will automatically:
1. Import your certificate into the CI runner's keychain
2. Sign the app with your Developer ID
3. Create the DMG
4. Submit the DMG to Apple for notarization
5. Wait for notarization to complete (usually 2-5 minutes)
6. Staple the notarization ticket to the DMG
7. Upload the signed and notarized DMG to the release

## Testing the Signed App

On a **different Mac** (not your development machine):

1. Download the DMG from GitHub Releases
2. Mount the DMG
3. Drag SpeakType.app to Applications
4. **Double-click** to open (should NOT show a Gatekeeper warning)

### Verify Signature

```bash
# Check the signature
codesign -dv --verbose=4 /Applications/SpeakType.app

# Should show:
# Authority=Developer ID Application: Your Name (TEAMID)
# Sealed Resources=version 2, flags=0x10000

# Check notarization
spctl -a -vv /Applications/SpeakType.app

# Should show:
# /Applications/SpeakType.app: accepted
# source=Notarized Developer ID
```

## Troubleshooting

### "No identity found" error in GitHub Actions

**Cause**: Certificate not properly imported or password incorrect

**Solution**: 
- Verify `DEVELOPER_ID_APPLICATION_CERT_PASSWORD` is correct
- Ensure the base64-encoded cert is complete (no truncation)

### Notarization fails with "Invalid credentials"

**Cause**: Wrong Apple ID or app-specific password

**Solution**:
- Verify `NOTARIZATION_APPLE_ID` matches your Apple ID
- Generate a new app-specific password if needed

### Notarization returns "rejected"

**Cause**: App doesn't meet Apple's requirements

**Solution**:
- Check notarization logs: `xcrun notarytool log <submission-id>`
- Common issues: missing hardened runtime, invalid entitlements

### User still sees Gatekeeper warning

**Cause**: Either the app wasn't signed/notarized properly, or the user is on an old macOS version

**Solution**:
- Verify signature with `codesign -dv /Applications/SpeakType.app`
- Check macOS version (notarization requires 10.15+)
- User workaround: Right-click → Open (instead of double-click)

## Local Development

For local development, you don't need to sign with Developer ID. macOS will allow you to run unsigned apps that you built yourself.

If you want to test the full signing/notarization locally:

```bash
# Build
xcodebuild -scheme speaktype -configuration Release

# Sign
codesign --force --deep --sign "Developer ID Application: Your Name" \
  ~/Library/Developer/Xcode/DerivedData/speaktype-*/Build/Products/Release/speaktype.app

# Create DMG
# ... (use make dmg)

# Notarize
xcrun notarytool submit SpeakType.dmg \
  --apple-id "your@email.com" \
  --password "xxxx-xxxx-xxxx-xxxx" \
  --team-id "TEAMID" \
  --wait

# Staple
xcrun stapler staple SpeakType.dmg
```

## Security Best Practices

1. **Never commit** certificates or passwords to git
2. **Rotate** app-specific passwords periodically
3. **Use GitHub Secrets** for all sensitive data
4. **Limit access** to repository secrets to trusted maintainers
5. **Monitor** Apple Developer account for unauthorized certificate usage

## Additional Resources

- [Apple Code Signing Guide](https://developer.apple.com/support/code-signing/)
- [Apple Notarization Overview](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution)
- [notarytool Documentation](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution/customizing_the_notarization_workflow)
