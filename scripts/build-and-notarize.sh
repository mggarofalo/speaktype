#!/bin/bash
# Build, sign, notarize, and staple DMG for release
# This script does the heavy lifting that used to happen in GitHub Actions
# Usage: ./scripts/build-and-notarize.sh v1.2.3

set -e

VERSION="$1"

if [ -z "$VERSION" ]; then
  echo "❌ Error: Version required"
  echo "Usage: ./scripts/build-and-notarize.sh v1.2.3"
  exit 1
fi

# Strip 'v' prefix if present for DMG name
VERSION_NUMBER="${VERSION#v}"
DMG_NAME="SpeakType-${VERSION_NUMBER}.dmg"

echo "🚀 Building Release: $VERSION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check for required credentials in keychain
if ! xcrun notarytool history --keychain-profile "AC_PASSWORD" &>/dev/null; then
  echo "❌ Keychain profile 'AC_PASSWORD' not found"
  echo ""
  echo "═══════════════════════════════════════════════════════"
  echo "  First-time setup required"
  echo "═══════════════════════════════════════════════════════"
  echo ""
  echo "You need an app-specific password for notarization."
  echo ""
  echo "How to get it:"
  echo "  1. Go to: https://appleid.apple.com"
  echo "  2. Sign in with: mail2048labs@gmail.com"
  echo "  3. Security → App-Specific Passwords"
  echo "  4. Generate password (or use existing one)"
  echo ""
  read -p "Enter app-specific password (without dashes): " -s APP_PASSWORD
  echo ""
  
  if [ -z "$APP_PASSWORD" ]; then
    echo "❌ Password required"
    exit 1
  fi
  
  echo "Storing credentials in Keychain..."
  xcrun notarytool store-credentials "AC_PASSWORD" \
    --apple-id "mail2048labs@gmail.com" \
    --team-id "PCV4UMSRZX" \
    --password "$APP_PASSWORD"
  
  echo ""
  echo "✅ Setup complete! Continuing with build..."
  echo ""
fi

# Get APPLE_TEAM_ID from environment or use default
APPLE_TEAM_ID="${APPLE_TEAM_ID:-PCV4UMSRZX}"

echo "🏗️  Building Release..."
xcodebuild -scheme "speaktype" \
  -configuration Release \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  ENABLE_HARDENED_RUNTIME=YES \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
  clean build

echo ""
echo "🔍 Verifying app signature..."
APP_PATH=$(find build -name "speaktype.app" -type d | head -n 1)

if [ -z "$APP_PATH" ]; then
  echo "❌ Error: Could not find speaktype.app!"
  exit 1
fi

codesign --verify --deep --strict "$APP_PATH"
echo "✅ App signature verified"

echo ""
echo "💿 Creating DMG..."

# Create background if needed
if [ ! -f "dmg-assets/dmg-background.png" ]; then
  cd dmg-assets
  python3 create-background.py 2>/dev/null || ./create-background.sh 2>/dev/null || echo "⚠️  Using default background"
  cd ..
fi

# Remove old DMG if exists
[ -f "$DMG_NAME" ] && rm "$DMG_NAME"

create-dmg \
  --volname "SpeakType" \
  --volicon "speaktype/Assets.xcassets/AppIcon.appiconset/icon_512x512.png" \
  --background "dmg-assets/dmg-background.png" \
  --window-pos 200 120 \
  --window-size 660 400 \
  --icon-size 160 \
  --icon "speaktype.app" 180 170 \
  --hide-extension "speaktype.app" \
  --app-drop-link 480 170 \
  "$DMG_NAME" \
  "$APP_PATH"

echo ""
echo "🔐 Signing DMG..."
codesign --sign "Developer ID Application" \
  --force \
  --timestamp \
  --options runtime \
  "$DMG_NAME"

codesign --verify --deep --strict "$DMG_NAME"
echo "✅ DMG signed"

echo ""
echo "🔒 Submitting for notarization..."
echo "(This typically takes 2-5 minutes)"
echo ""

SUBMIT_OUTPUT=$(xcrun notarytool submit "$DMG_NAME" \
  --keychain-profile "AC_PASSWORD" \
  --wait \
  2>&1)

echo "$SUBMIT_OUTPUT"

# Extract submission ID for potential troubleshooting
SUBMISSION_ID=$(echo "$SUBMIT_OUTPUT" | grep -E '^\s*id:' | head -1 | awk '{print $2}')

if echo "$SUBMIT_OUTPUT" | grep -q "status: Accepted"; then
  echo ""
  echo "✅ Notarization successful!"
  
  echo ""
  echo "📎 Stapling ticket..."
  xcrun stapler staple "$DMG_NAME"
  xcrun stapler validate "$DMG_NAME"
  
  echo ""
  echo "🔍 Final verification..."
  spctl --assess --type open --context context:primary-signature --verbose "$DMG_NAME" || true
  
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "🎉 SUCCESS! Release ready: $DMG_NAME"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "Next steps:"
  echo "  1. Test the DMG: open $DMG_NAME"
  echo "  2. Create GitHub release:"
  echo "     gh release create $VERSION $DMG_NAME --generate-notes"
  echo ""
else
  echo ""
  echo "❌ Notarization failed!"
  
  if [ -n "$SUBMISSION_ID" ]; then
    echo ""
    echo "Fetching detailed logs..."
    xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "AC_PASSWORD"
  fi
  
  exit 1
fi
