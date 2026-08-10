#!/bin/bash
# release.sh — Cut a release: bump the version, land it on main via PR, tag it.
#
# Usage:
#   ./scripts/release.sh               # infer the bump from Conventional Commits
#   ./scripts/release.sh minor         # force major / minor / patch
#   ./scripts/release.sh 1.2.3         # pin an exact version
#   ./scripts/release.sh --dry-run     # print the plan, change nothing
#   ./scripts/release.sh --skip-checks # skip the build + unit-test gate
#
# Bump inference, from the commits since the last tag:
#   feat!: / fix!: / BREAKING CHANGE:  → major
#   feat:                              → minor
#   everything else                    → patch
#
# A "release" here is a version bump plus a git tag. The app is self-signed for
# local/dev distribution (see AGENTS.md), so there is no notarized DMG and no
# GitHub Release object — the tag is the release.
#
# Why the PR dance: the `main` ruleset requires a pull request and has no bypass
# actors, so the bump cannot be pushed straight to main. The script branches,
# opens a PR, merges it, and only then tags. Tagging last is deliberate — it
# means a failure part-way through never leaves a stray tag behind, and every
# tag lands on main's merge commit rather than on a branch commit.

set -euo pipefail

PROJECT_FILE="speaktype.xcodeproj/project.pbxproj"
REPO="mggarofalo/speaktype"
BASE_BRANCH="main"

DRY_RUN=false
SKIP_CHECKS=false
BUMP_ARG=""

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --skip-checks) SKIP_CHECKS=true ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "❌ Unknown flag: $arg"; exit 1 ;;
    *) BUMP_ARG="$arg" ;;
  esac
done

die() { echo "❌ $1" >&2; exit 1; }

# ── Locate gh ─────────────────────────────────────────────────────────────────
# Not always on PATH for non-interactive shells (Homebrew installs to
# /opt/homebrew/bin, which a bare `sh -c` environment may not include).
GH="$(command -v gh || true)"
[ -n "$GH" ] || [ ! -x /opt/homebrew/bin/gh ] || GH=/opt/homebrew/bin/gh
[ -n "$GH" ] || die "gh is required (brew install gh)."

# ── Preflight ─────────────────────────────────────────────────────────────────
[ -f "$PROJECT_FILE" ] || die "Run this from the project root."

"$GH" auth status >/dev/null 2>&1 || die "gh is not authenticated (gh auth login)."

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
[ "$CURRENT_BRANCH" = "$BASE_BRANCH" ] \
  || die "Release from $BASE_BRANCH (currently on $CURRENT_BRANCH)."

git diff-index --quiet HEAD -- || {
  echo "❌ Uncommitted changes:" >&2
  git status --short >&2
  exit 1
}

echo "🔄 Fetching origin..."
git fetch --quiet origin "$BASE_BRANCH"
[ "$(git rev-parse HEAD)" = "$(git rev-parse "origin/$BASE_BRANCH")" ] \
  || die "$BASE_BRANCH is not in sync with origin/$BASE_BRANCH — pull or push first."

# ── Determine version ─────────────────────────────────────────────────────────
CURRENT_VERSION=$(perl -ne 'print $1 and exit if /MARKETING_VERSION = ([^;]+);/' "$PROJECT_FILE")
MAJOR=$(echo "$CURRENT_VERSION" | cut -d. -f1)
MINOR=$(echo "$CURRENT_VERSION" | cut -d. -f2)
PATCH=$(echo "$CURRENT_VERSION" | cut -d. -f3)

# Commits since the last release. Falls back to all history if the tag is gone.
if git rev-parse "v${CURRENT_VERSION}" >/dev/null 2>&1; then
  RANGE="v${CURRENT_VERSION}..HEAD"
else
  RANGE="HEAD"
fi

# ── Infer the bump from Conventional Commits ──────────────────────────────────
# feat!: / fix!: / any type with ! → major       (breaking)
# feat:                            → minor       (new capability)
# everything else                  → patch
#
# Merge commits are scanned too but never decide anything on their own: their
# subject is "Merge pull request #N from …", so the underlying `feat:` commit in
# the same range is what registers.
infer_level() {
  local subjects bodies feat_count breaking
  subjects=$(git log --format=%s "$RANGE" 2>/dev/null || true)
  bodies=$(git log --format=%B "$RANGE" 2>/dev/null || true)

  # `!` before the colon, or a BREAKING CHANGE footer (spec allows either).
  breaking=$(printf '%s\n' "$subjects" | grep -E '^[a-zA-Z]+(\([^)]*\))?!:' | head -1 || true)
  if [ -n "$breaking" ]; then
    INFER_LEVEL=major
    INFER_REASON="breaking change — ${breaking}"
    return
  fi
  if printf '%s\n' "$bodies" | grep -qE '^BREAKING[ -]CHANGE:'; then
    INFER_LEVEL=major
    INFER_REASON="breaking change — BREAKING CHANGE footer"
    return
  fi

  feat_count=$(printf '%s\n' "$subjects" | grep -cE '^feat(\([^)]*\))?:' || true)
  if [ "$feat_count" -gt 0 ]; then
    INFER_LEVEL=minor
    INFER_REASON="${feat_count} feat: commit(s)"
    return
  fi

  INFER_LEVEL=patch
  INFER_REASON="no feat: or breaking commits"
}

case "$BUMP_ARG" in
  "")
    infer_level
    BUMP_SOURCE="inferred — ${INFER_REASON}"
    case "$INFER_LEVEL" in
      major) VERSION="$((MAJOR + 1)).0.0" ;;
      minor) VERSION="${MAJOR}.$((MINOR + 1)).0" ;;
      *)     VERSION="${MAJOR}.${MINOR}.$((PATCH + 1))" ;;
    esac
    LEVEL="$INFER_LEVEL"
    ;;
  patch) VERSION="${MAJOR}.${MINOR}.$((PATCH + 1))"; LEVEL=patch; BUMP_SOURCE="forced" ;;
  minor) VERSION="${MAJOR}.$((MINOR + 1)).0";        LEVEL=minor; BUMP_SOURCE="forced" ;;
  major) VERSION="$((MAJOR + 1)).0.0";               LEVEL=major; BUMP_SOURCE="forced" ;;
  *)
    VERSION="$BUMP_ARG"
    [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
      || die "Version must be semver (e.g. 1.2.3), or one of: major minor patch"
    LEVEL="pinned"
    BUMP_SOURCE="explicit"
    ;;
esac

# A forced bump smaller than the commits imply is usually a mistake — v1.0.34
# shipped a feat: as a patch that way. Warn, but let it through.
if [ "$BUMP_SOURCE" = "forced" ] || [ "$LEVEL" = "pinned" ]; then
  infer_level
  if [ "$INFER_LEVEL" != "$LEVEL" ]; then
    echo "⚠️  Commits since v${CURRENT_VERSION} suggest a ${INFER_LEVEL} bump (${INFER_REASON})." >&2
  fi
fi

git rev-parse "v${VERSION}" >/dev/null 2>&1 && die "Tag v${VERSION} already exists locally."
git ls-remote --exit-code --tags origin "v${VERSION}" >/dev/null 2>&1 \
  && die "Tag v${VERSION} already exists on origin."

CURRENT_BUILD=$(perl -ne 'print $1 and exit if /CURRENT_PROJECT_VERSION = (\d+);/' "$PROJECT_FILE")
NEXT_BUILD=$((CURRENT_BUILD + 1))
RELEASE_BRANCH="chore/release-v${VERSION}"

echo ""
echo "📈 v${CURRENT_VERSION} (build ${CURRENT_BUILD}) → v${VERSION} (build ${NEXT_BUILD})"
echo "   bump   : ${LEVEL} (${BUMP_SOURCE})"
echo "   branch : ${RELEASE_BRANCH} → PR → ${BASE_BRANCH}"
echo "   tag    : v${VERSION} on ${BASE_BRANCH} after merge"
echo ""
git log --oneline "$RANGE" 2>/dev/null | sed 's/^/   /' || true
echo ""

if [ "$DRY_RUN" = true ]; then
  echo "🧪 Dry run — nothing changed."
  exit 0
fi

# ── Gate: the tag must point at something that builds and passes ──────────────
if [ "$SKIP_CHECKS" = true ]; then
  echo "⚠️  Skipping the build + test gate (--skip-checks)."
else
  echo "🔨 Building Release..."
  xcodebuild -project speaktype.xcodeproj -scheme speaktype -configuration Release build \
    >/tmp/speaktype-release-build.log 2>&1 \
    || { grep -E "error:" /tmp/speaktype-release-build.log | head -20; \
         die "Release build failed (full log: /tmp/speaktype-release-build.log)"; }

  # Unit tests only. speaktypeUITests needs assistive access the test runner is
  # not granted, so it fails on an otherwise healthy tree — see AGENTS.md.
  echo "🧪 Running unit tests..."
  xcodebuild test -project speaktype.xcodeproj -scheme speaktype -destination 'platform=macOS' \
    -only-testing:speaktypeTests >/tmp/speaktype-release-test.log 2>&1 \
    || { grep -E "error:|failed on" /tmp/speaktype-release-test.log | head -20; \
         die "Unit tests failed (full log: /tmp/speaktype-release-test.log)"; }
  echo "✅ Build and unit tests pass."
fi

# ── Bump on a release branch ──────────────────────────────────────────────────
echo "🌿 Creating ${RELEASE_BRANCH}..."
git checkout -q -b "$RELEASE_BRANCH"

perl -0pi -e "s/(MARKETING_VERSION = )[^;]+;/\${1}${VERSION};/g" "$PROJECT_FILE"
perl -0pi -e "s/(CURRENT_PROJECT_VERSION = )\d+;/\${1}${NEXT_BUILD};/g" "$PROJECT_FILE"

git add "$PROJECT_FILE"
git commit -q -m "chore: release v${VERSION}"
git push -q -u origin "$RELEASE_BRANCH"

# ── PR, merge, tag ────────────────────────────────────────────────────────────
echo "🔀 Opening PR..."
NOTES=$(git log --oneline "v${CURRENT_VERSION}..${BASE_BRANCH}" 2>/dev/null | sed 's/^/- /' || true)
PR_URL=$("$GH" pr create --repo "$REPO" --base "$BASE_BRANCH" --head "$RELEASE_BRANCH" \
  --title "chore: release v${VERSION}" \
  --body "Version bump for **v${VERSION}** (build ${NEXT_BUILD}).

Tag \`v${VERSION}\` is pushed once this merges, pointing at the merge commit on \`${BASE_BRANCH}\`.

## Since v${CURRENT_VERSION}

${NOTES:-_No commits found since the previous tag._}")
echo "   ${PR_URL}"

echo "⏳ Merging..."
for attempt in 1 2 3 4 5; do
  if "$GH" pr merge "$PR_URL" --repo "$REPO" --merge --delete-branch >/dev/null 2>&1; then
    break
  fi
  [ "$attempt" -lt 5 ] || die "Could not merge ${PR_URL}. The branch and bump commit are pushed; merge it by hand, then tag ${BASE_BRANCH} with v${VERSION}."
  sleep 5
done

git checkout -q "$BASE_BRANCH"
git pull -q --ff-only
git branch -q -D "$RELEASE_BRANCH" 2>/dev/null || true

# Tag the merge commit, so tags sit on main rather than on a deleted branch.
git tag "v${VERSION}"
git push -q origin "v${VERSION}"

echo ""
echo "🎉 v${VERSION} released"
echo "   tag    : $(git rev-parse --short HEAD) on ${BASE_BRANCH}"
echo "   compare: https://github.com/${REPO}/compare/v${CURRENT_VERSION}...v${VERSION}"
echo ""
echo "Install it with: make install"
