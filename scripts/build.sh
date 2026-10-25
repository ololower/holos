#!/bin/bash
# Збирає Holos.app у build/. З прапорцем --install ще й копіює в /Applications і запускає.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -d Vendor/whisper.xcframework || ! -f Resources/ggml-silero-v6.2.0.bin ]]; then
    echo "Немає залежностей — спершу запустіть scripts/fetch-deps.sh" >&2
    exit 1
fi

swift build -c release --arch arm64
# Тека з результатом залежить від версії Swift (.build/arm64-apple-macosx/release, .build/out/Products/Release…)
BIN_PATH="$(swift build -c release --arch arm64 --show-bin-path)"

APP=build/Holos.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN_PATH/Holos" "$APP/Contents/MacOS/Holos"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Коміт, з якого зібрано, — видно в меню Holos («Версія …»). Номер збірки — кількість комітів:
# завжди зростає. Версію (CFBundleShortVersionString) піднімають вручну в Resources/Info.plist
/usr/libexec/PlistBuddy -c "Add :HolosCommit string $(git describe --always --dirty 2>/dev/null || echo невідомо)" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD 2>/dev/null || echo 1)" "$APP/Contents/Info.plist"
cp Resources/ggml-silero-v6.2.0.bin Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R Vendor/whisper.xcframework/macos-arm64_x86_64/whisper.framework "$APP/Contents/Frameworks/"

# Локальний сертифікат (scripts/setup-signing.sh) — дозволи переживають перезбирання.
# Без нього ad-hoc: після кожного перезбирання дозволи доведеться надавати знову.
IDENTITY="Holos Local Signing"
if ! security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    echo "Сертифіката «${IDENTITY}» немає — підписую ad-hoc (запустіть scripts/setup-signing.sh)"
    IDENTITY="-"
fi
codesign --force --sign "$IDENTITY" "$APP/Contents/Frameworks/whisper.framework"
codesign --force --sign "$IDENTITY" "$APP"
echo "Зібрано: $(pwd)/$APP"

if ! ls "$HOME/Library/Application Support/Holos/models/"ggml-*.bin >/dev/null 2>&1; then
    echo "Моделі розпізнавання ще немає — завантажте її: scripts/download-model.sh"
fi

if [[ "${1:-}" == "--install" ]]; then
    pkill -x Holos 2>/dev/null && sleep 1 || true
    rm -rf /Applications/Holos.app
    cp -R "$APP" /Applications/Holos.app
    open /Applications/Holos.app
    echo "Встановлено й запущено: /Applications/Holos.app"
fi
