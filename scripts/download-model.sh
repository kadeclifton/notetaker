#!/usr/bin/env bash
# Downloads a whisper.cpp model into ~/.config/murmur/models (or $MURMUR_HOME/models).
#
#   scripts/download-model.sh              # small.en (466 MB): fast, good for English
#   scripts/download-model.sh medium.en    # medium.en (1.5 GB): more accurate, slower
#   scripts/download-model.sh small        # multilingual variants: small, medium
#   scripts/download-model.sh large-v3-turbo
#
# Then point transcription.whisperCpp.model in config.json at the file if it is not small.en.
set -euo pipefail

MODEL="${1:-small.en}"
case "$MODEL" in
    tiny|tiny.en|base|base.en|small|small.en|medium|medium.en|large-v3|large-v3-turbo) ;;
    *) echo "Unknown model '$MODEL'. Try small.en, medium.en, small, medium, large-v3-turbo." >&2; exit 1 ;;
esac

DIR="${MURMUR_HOME:-$HOME/.config/murmur}/models"
FILE="$DIR/ggml-$MODEL.bin"
URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$MODEL.bin"

mkdir -p "$DIR"
if [[ -s "$FILE" ]]; then
    echo "Already have $FILE"
    exit 0
fi
echo "Downloading $URL"
curl -L --fail --progress-bar -o "$FILE.part" "$URL"
mv "$FILE.part" "$FILE"
echo "Saved $FILE"
if [[ "$MODEL" != "small.en" ]]; then
    echo "Set \"model\": \"models/ggml-$MODEL.bin\" under transcription.whisperCpp in config.json"
fi
