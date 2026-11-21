#!/bin/zsh
# Builds CouchSync and publishes it as a GitHub Release.
#
#   ./release.sh            # next patch version (v1.0 -> v1.0.1)
#   ./release.sh 1.1        # a specific version
#   ./release.sh 1.1 "Notes"
#
# GitHub Actions runs this on every push to main (.github/workflows/release.yml).
# Locally it needs the GitHub CLI (gh), signed in, and your changes committed.
set -euo pipefail
cd "$(dirname "$0")"

git fetch -q --tags origin

if [[ -z "${CI:-}" ]]; then
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "There are uncommitted changes. Commit them first." >&2
    exit 1
  fi
  git push -q origin HEAD
fi

if [[ -n "$(git tag --points-at HEAD --list 'v*')" ]]; then
  echo "This commit is already released as $(git tag --points-at HEAD --list 'v*' | head -1)."
  exit 0
fi

VERSION="${1:-}"
VERSION="${VERSION#v}"
if [[ -z "$VERSION" ]]; then
  LATEST="$(git tag --list 'v*' --sort=-v:refname | head -1)"
  LATEST="${LATEST#v}"
  if [[ -z "$LATEST" ]]; then
    VERSION="1.0"
  else
    parts=("${(@s/./)LATEST}")
    while (( ${#parts} < 3 )); do parts+=0; done
    VERSION="${parts[1]}.${parts[2]}.$(( parts[3] + 1 ))"
  fi
fi
TAG="v$VERSION"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "$TAG already exists." >&2
  exit 1
fi
echo "Releasing $TAG"

VERSION="$VERSION" ./build.sh
ZIP="build/CouchSync-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/CouchSync.app "$ZIP"
# Also as plain CouchSync.zip, so .../releases/latest/download/CouchSync.zip
# always fetches the newest version (the download page links to it).
cp "$ZIP" build/CouchSync.zip

# Notes: as given, else the commit subjects since the last release. The app
# shows everything above "### Install" in its update window.
NOTES="${2:-}"
if [[ -z "$NOTES" ]]; then
  PREV="$(git tag --list 'v*' --sort=-v:refname | head -1)"
  CHANGES="$(git log --no-merges --format='- %s' ${PREV:+$PREV..}HEAD)"
  [[ -n "$CHANGES" ]] && NOTES="### What's new
$CHANGES"
fi
INSTALL='### Install

1. Download **CouchSync.zip** below (or from https://henrybeedham.github.io/couchsync/) and unzip it.
2. Move **CouchSync.app** to Applications.
3. The app is not notarized, so macOS will block it the first time. Clear that once in Terminal:

       xattr -dr com.apple.quarantine /Applications/CouchSync.app

Needs an Apple silicon Mac on macOS 14 or later.'

# The tag is created on GitHub at this commit.
gh release create "$TAG" "$ZIP" build/CouchSync.zip --target "$(git rev-parse HEAD)" \
  --title "CouchSync $VERSION" --generate-notes \
  --notes "${NOTES:+$NOTES

}$INSTALL"
git fetch -q --tags origin

echo "Released $TAG"
