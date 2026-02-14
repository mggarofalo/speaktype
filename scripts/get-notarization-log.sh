#!/bin/bash
# Get detailed notarization logs from Apple
# Usage: ./scripts/get-notarization-log.sh <submission-id>

if [ -z "$1" ]; then
  echo "Usage: $0 <submission-id>"
  echo "Example: $0 87a73b97-0b9f-494f-8fa8-c6c0f4f2031b"
  exit 1
fi

SUBMISSION_ID="$1"

# Check if credentials are available
if [ -z "$NOTARIZATION_APPLE_ID" ] || [ -z "$NOTARIZATION_PASSWORD" ] || [ -z "$APPLE_TEAM_ID" ]; then
  echo "Please set environment variables:"
  echo "  export NOTARIZATION_APPLE_ID='your@email.com'"
  echo "  export NOTARIZATION_PASSWORD='xxxx-xxxx-xxxx-xxxx'"
  echo "  export APPLE_TEAM_ID='ABC1234DEF'"
  exit 1
fi

echo "Fetching notarization log for submission: $SUBMISSION_ID"
echo ""

xcrun notarytool log "$SUBMISSION_ID" \
  --apple-id "$NOTARIZATION_APPLE_ID" \
  --password "$NOTARIZATION_PASSWORD" \
  --team-id "$APPLE_TEAM_ID"
