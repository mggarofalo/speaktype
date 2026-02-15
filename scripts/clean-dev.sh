#!/bin/bash

# Complete cleanup script for both dev and release builds
# Removes all app data and permissions for fresh testing

set -e

echo "🧹 Cleaning SpeakType (dev + release)..."
echo ""

# Kill ALL running instances (both dev and release)
pkill -9 -i speaktype 2>/dev/null || true
killall "SpeakType" 2>/dev/null || true
killall "speaktype" 2>/dev/null || true
sleep 1
echo "✅ Killed all running instances"

# Reset ALL permissions
tccutil reset Microphone com.2048labs.speaktype 2>/dev/null || true
tccutil reset Accessibility com.2048labs.speaktype 2>/dev/null || true
echo "✅ Reset microphone & accessibility permissions"

# Remove app preferences and data
defaults delete com.2048labs.speaktype 2>/dev/null || true
rm -rf ~/Library/Caches/com.2048labs.speaktype 2>/dev/null || true
rm -rf ~/Library/Saved\ Application\ State/com.2048labs.speaktype.savedState 2>/dev/null || true
rm -rf ~/Library/Preferences/com.2048labs.speaktype.plist 2>/dev/null || true
rm -rf ~/Library/Application\ Support/SpeakType 2>/dev/null || true
echo "✅ Removed app preferences & data"

# Remove BOTH dev and release installed versions
rm -rf /Applications/speaktype.app 2>/dev/null || true
rm -rf /Applications/SpeakType.app 2>/dev/null || true
echo "✅ Removed both dev & release apps"

echo ""
echo "✨ Clean complete!"
echo ""
echo "Next steps:"
echo "  • Dev: make run"
echo "  • Release: Install from DMG"
echo ""
