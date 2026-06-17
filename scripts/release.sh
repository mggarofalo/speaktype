#!/bin/bash
# release.sh — Cut a release: bump version, commit, tag, and push.
# Usage: ./scripts/release.sh [version]
#        No version → auto-bump the patch component.
#
# A "release" here is just a version bump + a git tag pushed to GitHub. The app
# is self-signed for local/dev distribution (see AGENTS.md), so there is no
# notarized DMG or GitHub Release artifact — the tag is the release.

set -euo pipefail

PROJECT_FILE="speaktype.xcodeproj/project.pbxproj"

# ── Preflight ─────────────────────────────────────────────────────────────────
[ -f "$PROJECT_FILE" ] || { echo "❌ Run from the project root."; exit 1; }

if ! git diff-index --quiet HEAD --; then
  echo "❌ You have uncommitted changes:"
  git status --short
  exit 1
fi

# ── Determine version ─────────────────────────────────────────────────────────
CURRENT_VERSION=$(perl -ne 'print $1 and exit if /MARKETING_VERSION = ([^;]+);/' "$PROJECT_FILE")

if [ "${1:-}" ]; then
  VERSION="$1"
  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "❌ Version must be semver (e.g. 1.2.3)"; exit 1; }
else
  MAJOR=$(echo "$CURRENT_VERSION" | cut -d. -f1)
  MINOR=$(echo "$CURRENT_VERSION" | cut -d. -f2)
  PATCH=$(echo "$CURRENT_VERSION" | cut -d. -f3)
  VERSION="${MAJOR}.${MINOR}.$((PATCH + 1))"
fi

if git rev-parse "v${VERSION}" >/dev/null 2>&1; then
  echo "❌ Tag v${VERSION} already exists."
  exit 1
fi

echo "📈 Releasing v${CURRENT_VERSION} → v${VERSION}"

# ── Bump version + build numbers (all configs) ────────────────────────────────
perl -0pi -e "s/(MARKETING_VERSION = )[^;]+;/\${1}${VERSION};/g" "$PROJECT_FILE"

CURRENT_BUILD=$(perl -ne 'print $1 and exit if /CURRENT_PROJECT_VERSION = (\d+);/' "$PROJECT_FILE")
NEXT_BUILD=$((CURRENT_BUILD + 1))
perl -0pi -e "s/(CURRENT_PROJECT_VERSION = )\d+;/\${1}${NEXT_BUILD};/g" "$PROJECT_FILE"

echo "  Version : v${VERSION}"
echo "  Build   : ${NEXT_BUILD}"

# ── Commit + tag + push ───────────────────────────────────────────────────────
git add "$PROJECT_FILE"
git commit -m "chore: release v${VERSION}"
git tag "v${VERSION}"

BRANCH=$(git rev-parse --abbrev-ref HEAD)
echo ""
echo "🔼 Pushing ${BRANCH} and tag v${VERSION}..."
git push origin "$BRANCH"
git push origin "v${VERSION}"

echo ""
echo "🎉 v${VERSION} released — https://github.com/mggarofalo/speaktype/releases/tag/v${VERSION}"
