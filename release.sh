#!/bin/zsh
# Builds CouchSync and publishes it as a GitHub Release.
#
#   ./release.sh 1.1            # tag v1.1 at the current commit
#   ./release.sh 1.1 "Notes"    # with your own release notes
#
# Needs the GitHub CLI (gh), signed in. Commit and push your changes first.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage: ./release.sh <version> [notes]}"
VERSION="${VERSION#v}"
TAG="v$VERSION"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "There are uncommitted changes. Commit them first." >&2
  exit 1
fi
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "$TAG already exists." >&2
  exit 1
fi

git push origin HEAD

VERSION="$VERSION" ./build.sh
ZIP="build/CouchSync-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/CouchSync.app "$ZIP"

NOTES="${2:-}"
INSTALL='### Install

1. Download **CouchSync-'"$VERSION"'.zip** below and unzip it.
2. Move **CouchSync.app** to Applications.
3. The app is not notarized, so macOS will block it the first time. Clear that once in Terminal:

       xattr -dr com.apple.quarantine /Applications/CouchSync.app

Needs an Apple silicon Mac on macOS 14 or later.'

git tag -a "$TAG" -m "CouchSync $VERSION"
git push origin "$TAG"
gh release create "$TAG" "$ZIP" --title "CouchSync $VERSION" \
  --notes "${NOTES:+$NOTES

}$INSTALL" --generate-notes

echo "Released $TAG"
