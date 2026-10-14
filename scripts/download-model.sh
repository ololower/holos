#!/bin/bash
# Завантажує модель whisper туди, де її шукає Holos.
# Використання: scripts/download-model.sh [large-v3|turbo]   (за замовчуванням large-v3)
set -euo pipefail

case "${1:-large-v3}" in
    large-v3)
        FILE="ggml-large-v3-q5_0.bin"
        SHA256="d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1"
        SIZE="1,1 ГБ"
        ;;
    turbo)
        FILE="ggml-large-v3-turbo-q8_0.bin"
        SHA256="317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1"
        SIZE="0,9 ГБ"
        ;;
    *)
        echo "Невідома модель: $1 (доступні: large-v3, turbo)" >&2
        exit 1
        ;;
esac

DIR="$HOME/Library/Application Support/Holos/models"
TARGET="$DIR/$FILE"

checksum() { shasum -a 256 "$1" | awk '{print $1}'; }

if [[ -f "$TARGET" && "$(checksum "$TARGET")" == "$SHA256" ]]; then
    echo "✓ Модель уже є: $TARGET"
    exit 0
fi

mkdir -p "$DIR"
echo "Завантажую $FILE ($SIZE)…"
# -C - докачує перерване завантаження
curl -fL --progress-bar -C - -o "$TARGET.part" "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$FILE"

ACTUAL=$(checksum "$TARGET.part")
if [[ "$ACTUAL" != "$SHA256" ]]; then
    rm -f "$TARGET.part"
    echo "Контрольна сума не збігається (очікувалося $SHA256, отримано $ACTUAL). Файл видалено, спробуйте ще раз." >&2
    exit 1
fi
mv "$TARGET.part" "$TARGET"
echo "✓ Модель збережено: $TARGET"
