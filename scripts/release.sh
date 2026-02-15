#!/bin/bash
# Complete release automation: version bump → build → sign → notarize → push → upload
# Usage: ./scripts/release.sh [version]
# If no version specified, auto-bumps patch version

set -e

echo "🚀 SpeakType Release Automation"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Step 0: Check for uncommitted changes
if ! git diff-index --quiet HEAD --; then
  echo "❌ Error: You have uncommitted changes"
  echo ""
  echo "Commit or stash changes before releasing:"
  git status --short
  exit 1
fi

# Step 1: Determine version
PROJECT_FILE="speaktype.xcodeproj/project.pbxproj"
CHANGELOG="CHANGELOG.md"

if [ ! -f "$PROJECT_FILE" ]; then
  echo "❌ Error: Must run from project root"
  exit 1
fi

# Get current version
CURRENT_VERSION=$(perl -ne 'print $1 and exit if /MARKETING_VERSION = ([^;]+);/' "$PROJECT_FILE")

if [ -z "$1" ]; then
  # Auto-bump patch version
  MAJOR=$(echo "$CURRENT_VERSION" | cut -d. -f1)
  MINOR=$(echo "$CURRENT_VERSION" | cut -d. -f2)
  PATCH=$(echo "$CURRENT_VERSION" | cut -d. -f3)
  NEW_PATCH=$((PATCH + 1))
  VERSION="${MAJOR}.${MINOR}.${NEW_PATCH}"
  echo "📈 Auto-bumping: v${CURRENT_VERSION} → v${VERSION}"
else
  VERSION="$1"
  # Validate semver format
  if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "❌ Error: Version must be semver (e.g., 1.2.3)"
    exit 1
  fi
  echo "📋 Using specified version: v${VERSION}"
fi

echo ""

# Step 2: Update version numbers
echo "🔢 Updating version numbers..."

# Bump MARKETING_VERSION
perl -0pi -e "s/(MARKETING_VERSION = )[^;]+;/\${1}${VERSION};/g" "$PROJECT_FILE"

# Bump CURRENT_PROJECT_VERSION (auto-increment)
CURRENT_BUILD=$(perl -ne 'print $1 and exit if /CURRENT_PROJECT_VERSION = (\d+);/' "$PROJECT_FILE")
if [ -z "$CURRENT_BUILD" ]; then
  echo "❌ Error: Could not read CURRENT_PROJECT_VERSION"
  exit 1
fi
NEXT_BUILD=$((CURRENT_BUILD + 1))
perl -0pi -e "s/(CURRENT_PROJECT_VERSION = )\\d+;/\${1}${NEXT_BUILD};/g" "$PROJECT_FILE"

echo "  Version: v${VERSION}"
echo "  Build: ${NEXT_BUILD}"

# Step 3: Update CHANGELOG
if [ -f "$CHANGELOG" ]; then
  echo ""
  echo "📝 Updating CHANGELOG..."
  RELEASE_DATE=$(date +%Y-%m-%d)
  perl -0pi -e "s/## \\[Unreleased\\]\\n- \\n/## [Unreleased]\\n- \\n\\n## [${VERSION}] - ${RELEASE_DATE}\\n- \\n/" "$CHANGELOG"
fi

# Step 4: Commit (but don't push yet!)
echo ""
echo "💾 Creating release commit..."
git add "$PROJECT_FILE" "$CHANGELOG"
git commit -m "release: v${VERSION}"
git tag "v${VERSION}"

echo ""
echo "📌 Tagged: v${VERSION} (not pushed yet)"

# Step 6: Check for notarization credentials
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔐 Checking notarization credentials..."
echo ""

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

# Step 7: Build
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🏗️  Building Release..."
echo ""

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

# Step 8: Create DMG
DMG_NAME="SpeakType-${VERSION}.dmg"

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

# Step 9: Notarize
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
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
  echo "🎉 SUCCESS! Build complete: $DMG_NAME"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  
  # Step 10: Push to remote (AFTER successful build)
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  read -p "🔼 Push v${VERSION} to GitHub? (y/n) " -n 1 -r
  echo ""
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    git push origin HEAD
    git push origin "v${VERSION}"
    echo "✅ Pushed to remote"
  else
    echo "⚠️  Skipped push. You can push manually later:"
    echo "     git push origin HEAD && git push origin v${VERSION}"
    echo ""
    echo "To undo the release commit:"
    echo "     git reset --hard HEAD~1"
    echo "     git tag -d v${VERSION}"
    exit 0
  fi
  
  # Step 11: Upload release to GitHub
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  read -p "📦 Upload $DMG_NAME to GitHub releases? (y/n) " -n 1 -r
  echo ""
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    if command -v gh &> /dev/null; then
      gh release create "v${VERSION}" "$DMG_NAME" --generate-notes
      echo ""
      echo "✅ Release published!"
      echo "   https://github.com/karansinghgit/speaktype/releases/tag/v${VERSION}"
    else
      echo "❌ GitHub CLI not installed. Install with: brew install gh"
    fi
  fi
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
