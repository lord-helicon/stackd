#!/bin/bash
# Usage: Tools/bump-version.sh X.Y.Z
# Sets CFBundleShortVersionString to X.Y.Z and increments CFBundleVersion in Resources/Info.plist.
# No git operations. Set PLIST=<path> to operate on another file (used for testing).
set -euo pipefail
cd "$(dirname "$0")/.."

PLIST="${PLIST:-Resources/Info.plist}"
PB=/usr/libexec/PlistBuddy
VERSION="${1:-}"

if [[ ! "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "usage: $0 X.Y.Z   (semantic version, e.g. 0.2.0)" >&2
    exit 1
fi

OLD=$("$PB" -c 'Print :CFBundleShortVersionString' "$PLIST")
BUILD=$("$PB" -c 'Print :CFBundleVersion' "$PLIST")
if [[ ! "$BUILD" =~ ^[0-9]+$ ]]; then
    echo "error: CFBundleVersion '$BUILD' is not an integer" >&2
    exit 1
fi
NEW_BUILD=$((BUILD + 1))

"$PB" -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
"$PB" -c "Set :CFBundleVersion $NEW_BUILD" "$PLIST"

echo "stackd $OLD (build $BUILD) -> $VERSION (build $NEW_BUILD)"
cat <<NEXT

Next steps:
  1. Commit the change on a branch and open a PR:  git switch -c release/$VERSION && git commit -am "Release $VERSION"
  2. Merge the PR into main.
  3. Tag and push:  git switch main && git pull && git tag -a v$VERSION -m "stackd $VERSION" && git push origin v$VERSION
  4. Watch the Release workflow, then: brew update && brew upgrade stackd
NEXT
