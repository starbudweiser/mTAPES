#!/bin/zsh
# Construit « mTAPES.app » (ou « mTAPES dev.app » avec DEV=1, bundle fr.stephan.mtapes.dev), la signe (certificat local stable)
# puis, hors DEV, l'installe dans ~/Applications/Applications Personnelles. NO_INSTALL=1 : ne pas installer ; NO_OPEN=1 : ne pas lancer.
set -euo pipefail
cd "$(dirname "$0")"
if [ -n "${DEV:-}" ]; then APP="mTAPES dev.app"; else APP="mTAPES.app"; fi
DEST="$HOME/Applications/Applications Personnelles"
rm -rf "${APP:?}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos15 -o "$APP/Contents/MacOS/mTAPES" Sources/MTapesEngine/*.swift App/*.swift

[ -f assets/AppIcon.icns ] && cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -n "${DEV:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier fr.stephan.mtapes.dev" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName mTAPES-dev" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName mTAPES-dev" "$APP/Contents/Info.plist"
fi

SIGN="/Volumes/SKYRIM/TOOLS/MAC/_tools/sign_app.sh"
if [ -x "$SIGN" ]; then "$SIGN" "$APP"; else codesign --force --deep -s - "$APP"; fi

if [ -z "${DEV:-}" ] && [ -z "${NO_INSTALL:-}" ]; then
  mkdir -p "$DEST"
  if pgrep -x mTAPES >/dev/null && [ -z "${FORCE:-}" ]; then
    echo "mTAPES tourne (une prise est peut-être en cours) : installation annulée. Relancer après l'arrêt, ou FORCE=1." >&2
    exit 2
  fi
  rm -rf "${DEST:?}/${APP:?}"
  cp -R "$APP" "$DEST/$APP"
  echo "Installée : $DEST/$APP"
fi
echo "OK : $APP"
