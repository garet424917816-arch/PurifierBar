#!/bin/bash
# Builds a release of Purifier Bar and publishes it as a GitHub release of the
# repository behind `origin` (needs the GitHub CLI `gh`, logged in).
#   release.sh <version> [notes]     e.g. release.sh 1.0 "First release"
# Steps: clean tree check -> annotated tag v<version> -> check.sh -> build-app.sh ->
# zip with ditto (keeps the signature) -> push the tag -> gh release create.
# Signing follows Tools/sign.sh; set PURIFIER_SIGN_IDENTITY=- for an ad-hoc signature.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
NOTES="${2:-Purifier Bar ${VERSION}}"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || { echo "usage: release.sh <version, e.g. 1.0> [notes]" >&2; exit 2; }
TAG="v$VERSION"

[ -z "$(git status --porcelain)" ] || { echo "release.sh: working tree is not clean" >&2; exit 1; }
git remote get-url origin >/dev/null 2>&1 || { echo "release.sh: no origin remote" >&2; exit 1; }
! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || { echo "release.sh: tag $TAG already exists" >&2; exit 1; }

./Tools/check.sh
git tag -a "$TAG" -m "Purifier Bar $VERSION"
# From here on a failure leaves only a local tag: remove it so the run can be repeated.
trap 'git tag -d "$TAG" >/dev/null 2>&1 || true' ERR

./Tools/build-app.sh
APP=build/PurifierBar.app
ZIP="build/PurifierBar-$VERSION.zip"
codesign --verify --deep --strict "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"

git push origin "$TAG"
trap - ERR
gh release create "$TAG" "$ZIP" --title "Purifier Bar $VERSION" \
    --notes "$NOTES

SHA-256 of PurifierBar-$VERSION.zip: \`$SHA\`"
echo "release.sh: $TAG published ($ZIP, sha256 $SHA)"
