#!/bin/bash
# Завантажує залежності збірки: whisper.cpp (xcframework) і детектор мовлення Silero VAD.
# Версії зафіксовано, кожен файл перевіряється за SHA-256 з офіційних джерел.
set -euo pipefail
cd "$(dirname "$0")/.."

WHISPER_BUILD="b5130" # whisper.cpp v1.9.4
WHISPER_SHA256="033a43b0174e8cf9b366f72e4a428cdcf126f93ad1c87d3fa119a96bed6f231a"
VAD_FILE="ggml-silero-v6.2.0.bin"
VAD_SHA256="2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987"

verify() {
    local actual
    actual=$(shasum -a 256 "$1" | awk '{print $1}')
    if [[ "$actual" != "$2" ]]; then
        echo "Контрольна сума не збігається: $1" >&2
        echo "  очікувалося: $2" >&2
        echo "  отримано:    $actual" >&2
        return 1
    fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [[ -d Vendor/whisper.xcframework && "$(cat Vendor/whisper.version 2>/dev/null)" == "$WHISPER_BUILD" ]]; then
    echo "✓ whisper.cpp ${WHISPER_BUILD} уже є"
else
    echo "Завантажую whisper.cpp ${WHISPER_BUILD} (57 МБ)…"
    curl -fL --progress-bar -o "$TMP/whisper.zip" \
        "https://github.com/ggml-org/whisper.cpp/releases/download/${WHISPER_BUILD}/whisper-${WHISPER_BUILD}-xcframework.zip"
    verify "$TMP/whisper.zip" "$WHISPER_SHA256"
    unzip -q "$TMP/whisper.zip" -d "$TMP/unpacked"
    rm -rf Vendor/whisper.xcframework
    mkdir -p Vendor
    mv "$TMP/unpacked/build-apple/whisper.xcframework" Vendor/
    echo "$WHISPER_BUILD" > Vendor/whisper.version
    echo "✓ whisper.cpp ${WHISPER_BUILD} → Vendor/whisper.xcframework"
fi

if [[ -f "Resources/$VAD_FILE" ]] && verify "Resources/$VAD_FILE" "$VAD_SHA256" 2>/dev/null; then
    echo "✓ Silero VAD уже є"
else
    echo "Завантажую Silero VAD (0,9 МБ)…"
    curl -fL --progress-bar -o "$TMP/$VAD_FILE" "https://huggingface.co/ggml-org/whisper-vad/resolve/main/$VAD_FILE"
    verify "$TMP/$VAD_FILE" "$VAD_SHA256"
    mv "$TMP/$VAD_FILE" "Resources/$VAD_FILE"
    echo "✓ Silero VAD → Resources/$VAD_FILE"
fi
