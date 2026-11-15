#!/bin/zsh
# Publie une version : compile, notarise (Apple), zippe, puis crée la release GitHub (pré-version tant que l'appli est un aperçu : PRERELEASE=0 pour une version stable).
# Usage : ./release.sh ["notes en anglais"]   — la version vient de CFBundleShortVersionString (Resources/Info.plist).
set -euo pipefail
cd "$(dirname "$0")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
TAG="v$VERSION"
DIST="$PWD/dist"
NOTES="${1:-mTAPES $VERSION}"
git diff --quiet && git diff --cached --quiet || { echo "Modifications non commitées : commiter avant la release." >&2; exit 1; }
! git rev-parse "$TAG" >/dev/null 2>&1 || { echo "La version $TAG existe déjà." >&2; exit 1; }
git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "main n'est pas synchronisé avec origin/main : pousser avant la release." >&2; exit 1; }

swift test 2>&1 | grep -E "Executed [0-9]+ tests, with 0 failures" >/dev/null || { echo "Les tests échouent : release annulée." >&2; exit 1; }
NO_INSTALL=1 ./build_app.sh
rm -rf "${DIST:?}"
DIST="$DIST" /Volumes/SKYRIM/TOOLS/MAC/_tools/notarize_app.sh mTAPES.app
ZIP="$DIST/mTAPES-$VERSION-macOS-arm64.zip"
mv "$DIST/mTAPES.zip" "$ZIP"
(cd "$DIST" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")

FLAGS=()
[ "${PRERELEASE:-1}" = 1 ] && FLAGS+=(--prerelease)
git tag "$TAG" && git push -q origin "$TAG"
gh release create "$TAG" "$ZIP" "$ZIP.sha256" --title "mTAPES $VERSION" --notes "$NOTES" "${FLAGS[@]}"
echo "✓ https://github.com/starbudweiser/mTAPES/releases/tag/$TAG"
