#!/bin/bash

# Builds and installs "SpeakType Beta.app" — a separate, coexisting app with its
# own bundle id (com.mggarofalo.speaktype.beta), so it has an independent TCC
# permission set and UserDefaults domain and can run alongside the production
# app for engine benchmarking. Signed with the same self-signed "SpeakType Local
# Dev" identity (TCC grants are per-bundle-id, so the Beta app prompts on first
# launch regardless).
#
# Only PRODUCT_BUNDLE_IDENTIFIER is overridden at build time (target-safe, like
# run-dev.sh). The display name / URL scheme are patched into the built app's
# Info.plist afterward, then the bundle is re-signed.

set -euo pipefail

BUNDLE_ID="com.mggarofalo.speaktype.beta"
CONFIG="Release"
SIGN_IDENTITY="SpeakType Local Dev"
ENTITLEMENTS="speaktype/Resources/speaktype.entitlements"
DERIVED_DATA_PATH="$PWD/build/beta-derived"
BUILD_PRODUCTS_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIG"
DEST_APP_PATH="/Applications/SpeakType Beta.app"

if [ ! -f "speaktype.xcodeproj/project.pbxproj" ]; then
  echo "Error: run this script from the project root."
  exit 1
fi

# Ensure the gitignored whisper.cpp xcframework is present before building.
bash scripts/fetch-whisper-xcframework.sh

echo "Building SpeakType Beta ($BUNDLE_ID, $CONFIG)..."
xcodebuild \
  -project speaktype.xcodeproj \
  -scheme speaktype \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  build

BUILD_APP_PATH="$(find "$BUILD_PRODUCTS_PATH" -maxdepth 1 -name "*.app" -type d | head -n 1)"
if [ -z "$BUILD_APP_PATH" ] || [ ! -d "$BUILD_APP_PATH" ]; then
  echo "Error: built app not found in $BUILD_PRODUCTS_PATH"
  exit 1
fi

# Distinguish the Beta app: display name, bundle name, and URL scheme, then
# re-sign (editing Info.plist invalidates the signature).
PLIST="$BUILD_APP_PATH/Contents/Info.plist"
echo "Patching Info.plist (display name + URL scheme)..."
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName SpeakType Beta" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleName SpeakType Beta" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLName com.mggarofalo.speaktype.beta" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 speaktype-beta" "$PLIST"

echo "Re-signing with '$SIGN_IDENTITY'..."
codesign --force --sign "$SIGN_IDENTITY" \
  --entitlements "$ENTITLEMENTS" \
  --generate-entitlement-der \
  "$BUILD_APP_PATH"

# Stop any running Beta instance before overwriting its bundle.
BETA_PROCESS_PATH="$DEST_APP_PATH/Contents/MacOS/speaktype"
if pgrep -f "$BETA_PROCESS_PATH" >/dev/null 2>&1; then
  echo "Stopping existing SpeakType Beta instance..."
  pkill -f "$BETA_PROCESS_PATH" || true
  sleep 1
fi

echo "Installing to $DEST_APP_PATH..."
ditto "$BUILD_APP_PATH" "$DEST_APP_PATH"

echo "Launching SpeakType Beta..."
open "$DEST_APP_PATH"

echo ""
echo "Bundle ID : $BUNDLE_ID"
echo "App Path  : $DEST_APP_PATH"
echo "Note: quit the production SpeakType app for clean benchmarking, and grant"
echo "      Accessibility + Microphone to SpeakType Beta on first launch."
