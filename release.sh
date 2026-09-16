#!/bin/bash
# Builds a new version and publishes it as a GitHub release. The app then
# picks it up by itself via Updates in Settings.
#
#   ./release.sh 1.2 "What's new"
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
VERSION="${1:?Usage: ./release.sh <version> [release notes]}"
NOTES="${2:-ShotShelf $VERSION}"
REPO="${UPDATE_REPO:-antaflu/shotshelf}"

echo "$VERSION" > "$ROOT/VERSION"
VERSION="$VERSION" UPDATE_REPO="$REPO" "$ROOT/build.sh"

DMG="$ROOT/build/ShotShelf-$VERSION.dmg"
( cd "$ROOT/build" && shasum -a 256 "ShotShelf-$VERSION.dmg" > "ShotShelf-$VERSION.dmg.sha256" )

git -C "$ROOT" add -A
git -C "$ROOT" commit -m "ShotShelf $VERSION" || true
git -C "$ROOT" tag "v$VERSION"
git -C "$ROOT" push origin HEAD --tags

gh release create "v$VERSION" "$DMG" "$DMG.sha256" \
  --repo "$REPO" --title "ShotShelf $VERSION" --notes "$NOTES"
echo "Release v$VERSION is live: https://github.com/$REPO/releases/tag/v$VERSION"
