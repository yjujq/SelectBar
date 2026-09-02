#!/bin/bash
# Собирает SelectBar.app и подписывает его.
#
# Подпись важна не для безопасности, а для работы разрешений: macOS привязывает
# выданный доступ к подписи приложения. Без неё доступ придётся выдавать заново
# после каждой пересборки.
set -euo pipefail
cd "$(dirname "$0")"

APP="SelectBar.app"
# Бандл собираем во временной папке вне «Рабочего стола»: он синхронизируется
# с iCloud, а файловый провайдер вешает атрибуты com.apple.FinderInfo и
# com.apple.fileprovider, которые codesign отвергает и которые возвращаются
# после очистки на месте.
PROJECT="$(pwd)"
STAGE="$(mktemp -d /tmp/selectbar-build.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
BIN="$STAGE/$APP/Contents/MacOS/SelectBar"

echo "==> сборка"
mkdir -p "$STAGE/$APP/Contents/MacOS" "$STAGE/$APP/Contents/Resources"
# main.swift обязан идти последним: Swift ищет точку входа именно в нём.
swiftc -O -o "$BIN" \
    $(ls Sources/*.swift | grep -v 'main\.swift$') Sources/main.swift \
    -framework AppKit -framework ApplicationServices
cp Info.plist "$STAGE/$APP/Contents/Info.plist"

if [ -d AppIcon.iconset ]; then
    iconutil -c icns AppIcon.iconset -o AppIcon.icns
fi
[ -f AppIcon.icns ] && cp AppIcon.icns "$STAGE/$APP/Contents/Resources/AppIcon.icns"

xattr -cr "$STAGE/$APP" 2>/dev/null || true

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
           | awk 'NR==1 && /\)/ {print $2}')
if [ -n "${IDENTITY:-}" ]; then
    echo "==> подпись ($IDENTITY)"
    codesign --force --sign "$IDENTITY" "$STAGE/$APP"
else
    echo "==> подпись ad-hoc (постоянной не нашлось)"
    codesign --force --sign - "$STAGE/$APP"
fi

# Проверка по коду возврата, а не по последней команде конвейера:
# иначе неудачная подпись проходит незамеченной.
if codesign --verify --strict "$STAGE/$APP" 2>/tmp/selectbar-codesign.txt; then
    echo "==> подпись действительна"
else
    echo "ОШИБКА: подпись не прошла проверку" >&2
    cat /tmp/selectbar-codesign.txt >&2
    exit 1
fi

echo "==> установка"
rm -rf "$PROJECT/$APP" "/Applications/$APP"
ditto "$STAGE/$APP" "$PROJECT/$APP"
ditto "$STAGE/$APP" "/Applications/$APP"

echo "Готово: /Applications/$APP"
echo "Запуск: open /Applications/$APP"
