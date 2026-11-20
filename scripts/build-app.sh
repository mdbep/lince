#!/bin/bash
# Compila Lince y genera dist/Lince.app y dist/Lince.dmg.
#   scripts/build-app.sh            compila y empaqueta
#   scripts/build-app.sh --install  además lo copia a /Applications y lo abre
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh   firma con esa identidad
set -euo pipefail

cd "$(dirname "$0")/.."
APP="dist/Lince.app"

swift build -c release

rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Lince" "$APP/Contents/MacOS/Lince"
cp Resources/Info.plist "$APP/Contents/Info.plist"

ICONSET="$(mktemp -d)/AppIcon.iconset"
swift scripts/make-icon.swift Resources/AppIcon.svg "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp Resources/MenuBarIcon.svg "$APP/Contents/Resources/MenuBarIcon.svg"

# Con una identidad estable, macOS conserva el permiso de grabación de pantalla entre compilaciones.
IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)"
fi
if [ -n "$IDENTITY" ] && codesign --force --sign "$IDENTITY" "$APP" 2>/dev/null; then
    echo "Firmado con una identidad de desarrollo."
else
    codesign --force --sign - "$APP"
    echo "Firmado ad hoc (el permiso de pantalla se pedirá de nuevo tras cada compilación)."
fi

STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Lince" -srcfolder "$STAGING" -ov -format UDZO -quiet dist/Lince.dmg
echo "Listo: $APP y dist/Lince.dmg"

if [ "${1:-}" = "--install" ]; then
    pkill -x Lince 2>/dev/null || true
    rm -rf /Applications/Lince.app
    cp -R "$APP" /Applications/
    open /Applications/Lince.app
    echo "Instalado en /Applications y abierto."
fi
