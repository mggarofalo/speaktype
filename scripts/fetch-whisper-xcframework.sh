#!/bin/bash

# Downloads the prebuilt whisper.cpp xcframework (Metal-enabled) from the
# ggml-org/whisper.cpp GitHub release and unpacks it into the local WhisperCPP
# package at Vendor/WhisperCPP/whisper.xcframework. The binary is gitignored, so
# run this once after checkout before building the beta with the whisper.cpp engine.

set -euo pipefail

WHISPER_VERSION="v1.8.7"
ASSET="whisper-${WHISPER_VERSION}-xcframework.zip"
URL="https://github.com/ggml-org/whisper.cpp/releases/download/${WHISPER_VERSION}/${ASSET}"
DEST_DIR="Vendor/WhisperCPP"
DEST_XCFRAMEWORK="${DEST_DIR}/whisper.xcframework"

if [ ! -f "speaktype.xcodeproj/project.pbxproj" ]; then
  echo "Error: run this script from the project root."
  exit 1
fi

if [ -d "$DEST_XCFRAMEWORK" ]; then
  echo "whisper.xcframework already present at $DEST_XCFRAMEWORK — nothing to do."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading $ASSET ..."
curl -fL -o "$TMP/whisper.zip" "$URL"

echo "Unpacking ..."
unzip -q "$TMP/whisper.zip" -d "$TMP/extracted"

SRC="$(find "$TMP/extracted" -maxdepth 3 -name 'whisper.xcframework' -type d | head -n 1)"
if [ -z "$SRC" ]; then
  echo "Error: whisper.xcframework not found in archive."
  exit 1
fi

mkdir -p "$DEST_DIR"
ditto "$SRC" "$DEST_XCFRAMEWORK"
echo "Installed whisper.xcframework -> $DEST_XCFRAMEWORK"
