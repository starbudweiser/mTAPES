#!/bin/zsh
# Publie une version : tests, compilation, notarisation (Apple), zip, puis release GitHub (pré-version tant que l'appli est un aperçu : PRERELEASE=0 pour une version stable).
# Usage : ./release.sh ["notes en anglais"]   — la version vient de CFBundleShortVersionString (Resources/Info.plist).
# La release est créée AVANT tout tag local ; GitHub crée le tag sur main (un échec en route ne laisse pas de tag orphelin).
set -euo pipefail
cd "$(dirname "$0")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
TAG="v$VERSION"
DIST="$PWD/dist"
NOTES="${1:-mTAPES $VERSION}"

gh auth status >/dev/null 2>&1 || { echo "gh n'est pas connecté : release annulée avant toute notarisation." >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Dépôt non propre (modifications ou fichiers non suivis) : commiter avant la release." >&2; exit 1; }
! gh release view "$TAG" -R starbudweiser/mTAPES >/dev/null 2>&1 || { echo "La release $TAG existe déjà." >&2; exit 1; }
[ -z "$(git ls-remote --tags origin "refs/tags/$TAG")" ] || { echo "Le tag $TAG existe déjà sur GitHub (supprimez-le ou changez de version)." >&2; exit 1; }
git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "main n'est pas synchronisé avec origin/main : pousser avant la release." >&2; exit 1; }

python3 tests/check_l10n.py || { echo "Textes incohérents entre les langues : release annulée." >&2; exit 1; }
swift test 2>&1 | grep -E "Executed [0-9]+ tests, with 0 failures" >/dev/null || { echo "Les tests échouent : release annulée." >&2; exit 1; }

rm -rf "${PWD:?}/mTAPES.app"
env -u DEV -u FORCE NO_INSTALL=1 ./build_app.sh
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' mTAPES.app/Contents/Info.plist)" = "fr.stephan.mtapes" ] || { echo "Identifiant de paquet inattendu : release annulée." >&2; exit 1; }
rm -rf "${DIST:?}"
# Droits minimaux : aucun (pas de JIT ni de mémoire exécutable) ; la capture d'écran passe par l'autorisation de confidentialité, pas par un droit.
APP_ENTITLEMENTS="$PWD/Resources/entitlements.plist" DIST="$DIST" /Volumes/SKYRIM/TOOLS/MAC/_tools/notarize_app.sh mTAPES.app
ZIP="$DIST/mTAPES-$VERSION-macOS-arm64.zip"
mv "$DIST/mTAPES.zip" "$ZIP"
(cd "$DIST" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")

FLAGS=()
[ "${PRERELEASE:-1}" = 1 ] && FLAGS+=(--prerelease)
gh release create "$TAG" "$ZIP" "$ZIP.sha256" --target main --title "mTAPES $VERSION" --notes "$NOTES" "${FLAGS[@]}"
git fetch -q --tags origin
echo "✓ https://github.com/starbudweiser/mTAPES/releases/tag/$TAG"
