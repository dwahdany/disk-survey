#!/bin/bash
# Builds a notarized release and publishes it on GitHub.
#
#   Scripts/release.sh [--publish] [--notes FILE]
#
# Steps: checks the working tree is clean and on a pushed commit, builds the universal app with
# Scripts/build-app.sh --notarize --dmg --zip, writes SHA-256 checksums, tags v<VERSION>, and
# creates a GitHub release with the dmg, zip and checksums attached.
#
#   --publish      publish the release immediately (default: create it as a DRAFT to review)
#   --notes FILE   release notes in Markdown (default: GitHub's generated notes)
#   -h, --help     show this help
#
# Needs: CODESIGN_IDENTITY ("Developer ID Application: Name (TEAMID)"), a notarytool keychain
# profile (NOTARY_PROFILE, default "disksurvey-notary"), and a logged-in `gh`.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

publish=0; notes=""
while [ $# -gt 0 ]; do
    case "$1" in
        --publish) publish=1 ;;
        --notes)   [ $# -ge 2 ] || die "--notes needs a file"; notes="$2"; shift ;;
        -h|--help) sed -n '2,/^$/p' "$0" | sed -e 's/^# \{0,1\}//'; exit 0 ;;
        *)         die "unknown option: $1" ;;
    esac
    shift
done

command -v gh >/dev/null 2>&1 || die "gh (GitHub CLI) not found"
gh auth status >/dev/null 2>&1 || die "gh is not logged in; run: gh auth login"
[ -n "${CODESIGN_IDENTITY:-}" ] || die "set CODESIGN_IDENTITY to your \"Developer ID Application: …\" identity"
[ -z "$notes" ] || [ -f "$notes" ] || die "notes file not found: $notes"

VERSION="$(tr -d ' \t\r\n' < VERSION)"
TAG="v$VERSION"

git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository"
[ -z "$(git status --porcelain)" ] || die "working tree has uncommitted changes; commit or stash them first"
git fetch --quiet --tags origin
[ -z "$(git tag -l "$TAG")" ] || die "tag $TAG already exists; bump VERSION (and DiskSurveyVersion.string)"
head="$(git rev-parse HEAD)"
git branch -r --contains "$head" | grep -q . || die "HEAD ($head) is not pushed; push it first so the tag points at a public commit"

say "Building and notarizing Disk Survey $VERSION"
Scripts/build-app.sh --notarize --dmg --zip

dmg="dist/DiskSurvey-$VERSION.dmg"; zip="dist/DiskSurvey-$VERSION.zip"; sums="dist/DiskSurvey-$VERSION-SHA256.txt"
[ -f "$dmg" ] && [ -f "$zip" ] || die "build did not produce $dmg and $zip"
( cd dist && shasum -a 256 "$(basename "$dmg")" "$(basename "$zip")" ) > "$sums"
cat "$sums"

say "Tagging $TAG"
git tag -a "$TAG" -m "Disk Survey $VERSION" "$head"
git push origin "$TAG"

args=("$TAG" "$dmg" "$zip" "$sums" --title "Disk Survey $VERSION" --verify-tag)
if [ -n "$notes" ]; then args+=(--notes-file "$notes"); else args+=(--generate-notes); fi
[ "$publish" -eq 1 ] || args+=(--draft)
say "Creating GitHub release $TAG$([ "$publish" -eq 1 ] || echo ' (draft)')"
gh release create "${args[@]}"
say "Done"
