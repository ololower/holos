#!/bin/bash
# Завантажує модель розпізнавання туди, де її шукає Holos.
# Використання: scripts/download-model.sh [large-v3|turbo|parakeet-ultra|parakeet-v3]   (за замовчуванням large-v3)
#   large-v3, turbo — whisper (рушій за замовчуванням)
#   parakeet-ultra, parakeet-v3 — Core ML-моделі для експериментального рушія Parakeet
set -euo pipefail

DIR="$HOME/Library/Application Support/Holos/models"

checksum() { shasum -a 256 "$1" | awk '{print $1}'; }

download_whisper() {
    local file=$1 sha256=$2 size=$3
    local target="$DIR/$file"
    if [[ -f "$target" && "$(checksum "$target")" == "$sha256" ]]; then
        echo "✓ Модель уже є: $target"
        return
    fi
    mkdir -p "$DIR"
    echo "Завантажую $file ($size)…"
    # -C - докачує перерване завантаження
    curl -fL --progress-bar -C - -o "$target.part" "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$file"
    local actual
    actual=$(checksum "$target.part")
    if [[ "$actual" != "$sha256" ]]; then
        rm -f "$target.part"
        echo "Контрольна сума не збігається (очікувалося $sha256, отримано $actual). Файл видалено, спробуйте ще раз." >&2
        exit 1
    fi
    mv "$target.part" "$target"
    echo "✓ Модель збережено: $target"
}

# Core ML-модель — тека з кількох файлів. Репозиторій закріплено на коміті, кожен файл
# перевіряється за SHA-256 з маніфесту («sha256  шлях_у_репозиторії  [локальний_шлях]»).
manifest_ok() {
    local root=$1 manifest=$2 sha src dst
    while read -r sha src dst; do
        [[ -z "$sha" ]] && continue
        [[ -f "$root/${dst:-$src}" && "$(checksum "$root/${dst:-$src}")" == "$sha" ]] || return 1
    done <<< "$manifest"
}

download_coreml() {
    local repo=$1 commit=$2 name=$3 size=$4 manifest=$5
    local target="$DIR/$name" staging="$DIR/$name.part" sha src dst actual
    if [[ -d "$target" ]] && manifest_ok "$target" "$manifest"; then
        echo "✓ Модель уже є: $target"
        return
    fi
    mkdir -p "$staging"
    echo "Завантажую $name ($size)…"
    while read -r sha src dst; do
        [[ -z "$sha" ]] && continue
        dst=${dst:-$src}
        mkdir -p "$(dirname "$staging/$dst")"
        # Уже завантажений з минулої спроби — не качаємо вдруге
        [[ -f "$staging/$dst" && "$(checksum "$staging/$dst")" == "$sha" ]] && continue
        echo "  $dst"
        curl -fL --progress-bar -C - -o "$staging/$dst" "https://huggingface.co/$repo/resolve/$commit/$src"
        actual=$(checksum "$staging/$dst")
        if [[ "$actual" != "$sha" ]]; then
            rm -f "$staging/$dst"
            echo "Контрольна сума не збігається для $dst (очікувалося $sha, отримано $actual). Файл видалено, спробуйте ще раз." >&2
            exit 1
        fi
    done <<< "$manifest"
    rm -rf "$target"
    mv "$staging" "$target"
    echo "✓ Модель збережено: $target"
}

case "${1:-large-v3}" in
    large-v3)
        download_whisper "ggml-large-v3-q5_0.bin" "d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1" "1,1 ГБ"
        ;;
    turbo)
        download_whisper "ggml-large-v3-turbo-q8_0.bin" "317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1" "0,9 ГБ"
        ;;
    parakeet-ultra)
        # moondream/parakeet-ultra — донавчена parakeet-tdt-0.6b-v3, Core ML від FluidInference (CC-BY-4.0)
        download_coreml "FluidInference/parakeet-ultra-coreml" "95eaa59a39d4394f047a4dc5cce480388a60d1b6" \
            "parakeet-ultra-coreml" "0,6 ГБ" "
c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d  Preprocessor.mlmodelc/analytics/coremldata.bin
129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea  Preprocessor.mlmodelc/weights/weight.bin
dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d  Preprocessor.mlmodelc/coremldata.bin
2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf  Preprocessor.mlmodelc/metadata.json
4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93  Preprocessor.mlmodelc/model.mil
d87101d824d6723cf95304da33755c3c60e762663b9ef2b0c4bd0aa166a09a0d  Encoder.mlmodelc/analytics/coremldata.bin
315ba01f33cadbf601d43ac7f5c86208b7aa75fdaa34705c9869d5abe3521c9b  Encoder.mlmodelc/weights/weight.bin
397a84a4062f563cbc5f56077c674f09a61d85be5090f61d2f1932afb92ac0fe  Encoder.mlmodelc/coremldata.bin
f5d601568a4171d99a314c0fe3f6bc67715da2623732a3fb566e050ea83e5848  Encoder.mlmodelc/model.mil
fe92b6cfaa012abd5248c0bc877832f19807015abffc60d87b8ccc8ccb48b3b5  Decoder.mlmodelc/analytics/coremldata.bin
02a0d219f281b9665bc10c8768649403b2eebbbf4b44c627041d948e0de11bb4  Decoder.mlmodelc/weights/weight.bin
3b06e66768f0df7e21795f50e2b29300e33eeb1a2579dc42c695279c2d308497  Decoder.mlmodelc/coremldata.bin
956f600207f88396017ca5c96cfa3acd5bfee60835a5b44b762e033a8fb28955  Decoder.mlmodelc/model.mil
68d38ca646aebafa7a9329e2efda50f5767c49e89fdb5f77f212072bb66f97c4  JointDecisionv3.mlmodelc/analytics/coremldata.bin
3f310b85b82341c53ec383025ab094a4e462ee1c592e1ad7c6bfe39cff66ca25  JointDecisionv3.mlmodelc/weights/weight.bin
5e3af5a4ce686f6c237cadbd9284e10d333bc0e1546633cd0e430e6194044bc4  JointDecisionv3.mlmodelc/coremldata.bin
791b3c3cf3eb2079c84623fc880f6bba008d1366e5f8b03e9a8ed8bd4d7194a0  JointDecisionv3.mlmodelc/model.mil
7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735  parakeet_vocab.json
"
        ;;
    parakeet-v3)
        # nvidia/parakeet-tdt-0.6b-v3, Core ML від FluidInference (CC-BY-4.0). Енкодер — Encoder_v2:
        # int8 без псування токенів, яке має початковий 6-бітний Encoder (FluidAudio issue #760)
        download_coreml "FluidInference/parakeet-tdt-0.6b-v3-coreml" "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe" \
            "parakeet-tdt-0.6b-v3-coreml" "0,6 ГБ" "
c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d  Preprocessor.mlmodelc/analytics/coremldata.bin
129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea  Preprocessor.mlmodelc/weights/weight.bin
dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d  Preprocessor.mlmodelc/coremldata.bin
2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf  Preprocessor.mlmodelc/metadata.json
4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93  Preprocessor.mlmodelc/model.mil
af98d71151609799efbbffc00112fcba4bd91adf0b01135a982c574e91822f9c  Encoder_v2.mlmodelc/analytics/coremldata.bin  Encoder.mlmodelc/analytics/coremldata.bin
8d2c79e15a4545e08fe3a21fe741e42b8bf24329db81de8fdfacd92388ea5a66  Encoder_v2.mlmodelc/weights/weight.bin  Encoder.mlmodelc/weights/weight.bin
70628bd4fd25fb554cc0cebc31356723930c885480132bf3ecd1b5dbe71dd0a2  Encoder_v2.mlmodelc/coremldata.bin  Encoder.mlmodelc/coremldata.bin
abc621390840dd064e6833dc098101706621e47e17119ead904f8c383211dd1d  Encoder_v2.mlmodelc/model.mil  Encoder.mlmodelc/model.mil
4238c4e81ecd0dc94bd7dfbb60f7e2cc824107c1ffe0387b8607b72833dba350  Decoder.mlmodelc/analytics/coremldata.bin
48adf0f0d47c406c8253d4f7fef967436a39da14f5a65e66d5a4b407be355d41  Decoder.mlmodelc/weights/weight.bin
18647af085d87bd8f3121c8a9b4d4564c1ede038dab63d295b4e745cf2d7fb99  Decoder.mlmodelc/coremldata.bin
a39e93cd8371b8ded92635c7804fcd0590f0d1dd9415c6d19a0484be073077d9  Decoder.mlmodelc/metadata.json
ef2a0a281695398a62fde86ac269c68f73d5b578d7ed3b31f2ba91a2d1ea1f35  Decoder.mlmodelc/model.mil
26def4bf73dd56d29dee21c8ef97cb8969e62f6120ed1adc91e46828e2737b6c  JointDecisionv3.mlmodelc/analytics/coremldata.bin
4e0e63d840032f7f07ddb1d64446051166281e5491bf22da8a945c41f6eedb3e  JointDecisionv3.mlmodelc/weights/weight.bin
f5fc08b741400f0088492c9e839418b1e18522f19cba28d361dd030c5f398342  JointDecisionv3.mlmodelc/coremldata.bin
d9307211b9a37e0f0ac260c7660b1571a3de25841035cfdf9b58fd40425f890f  JointDecisionv3.mlmodelc/metadata.json
be60732943389a047175111a83f8839f3eb39d4803adafa828a0871b2f39818d  JointDecisionv3.mlmodelc/model.mil
7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735  parakeet_vocab.json
"
        ;;
    *)
        echo "Невідома модель: $1 (доступні: large-v3, turbo, parakeet-ultra, parakeet-v3)" >&2
        exit 1
        ;;
esac
