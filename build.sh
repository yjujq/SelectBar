#!/bin/bash
# Собирает SelectBar.app и подписывает его.
#
# Подпись важна не для безопасности, а для работы разрешений: macOS привязывает
# выданный доступ к подписи приложения. Без неё доступ придётся выдавать заново
# после каждой пересборки.
set -euo pipefail
cd "$(dirname "$0")"

APP="SelectBar.app"
BIN="$APP/Contents/MacOS/SelectBar"

echo "==> сборка"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# main.swift обязан идти последним: Swift ищет точку входа именно в нём.
swiftc -O -o "$BIN" \
    $(ls Sources/*.swift | grep -v 'main\.swift$') Sources/main.swift \
    -framework AppKit -framework ApplicationServices
cp Info.plist "$APP/Contents/Info.plist"

# Иконка: если исходник изменился, пересобираем .icns из набора размеров.
if [ -d AppIcon.iconset ]; then
    iconutil -c icns AppIcon.iconset -o AppIcon.icns
fi
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
           | awk 'NR==1 && /\)/ {print $2}')
if [ -n "${IDENTITY:-}" ]; then
    echo "==> подпись ($IDENTITY)"
    codesign --force --sign "$IDENTITY" "$APP"
else
    echo "==> подпись ad-hoc (постоянной не нашлось)"
    codesign --force --sign - "$APP"
fi

codesign --verify --verbose=1 "$APP" 2>&1 | tail -1
echo
echo "Готово: $(pwd)/$APP"
echo "Запуск: open $APP"
