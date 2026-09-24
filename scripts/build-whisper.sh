#!/usr/bin/env bash
# Builds whisper.cpp's whisper-server and whisper-cli for Murmur to ship inside the app:
# Core ML (the encoder runs on the Neural Engine when its .mlmodelc is downloaded) plus Metal,
# linked statically so they need nothing from Homebrew. Output: build/whisper/bin.
#
#   scripts/build-whisper.sh                       # the pinned version
#   WHISPER_CPP_VERSION=v1.9.2 scripts/build-whisper.sh
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${WHISPER_CPP_VERSION:-v1.9.2}"
OUT="$PWD/build/whisper"
SRC="$OUT/src"

if [[ -x "$OUT/bin/whisper-server" && -x "$OUT/bin/whisper-cli" && "$(cat "$OUT/VERSION" 2>/dev/null)" == "$VERSION" ]]; then
    echo "whisper.cpp $VERSION already built in $OUT/bin"
    exit 0
fi

rm -rf "$SRC" "$OUT/bin"
mkdir -p "$OUT"
git clone --quiet --depth 1 --branch "$VERSION" https://github.com/ggml-org/whisper.cpp "$SRC"

# GGML_NATIVE=OFF: the runner may be a newer chip than yours; native code could crash on an M1.
cmake -S "$SRC" -B "$SRC/build" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF \
    -DWHISPER_COREML=ON -DWHISPER_COREML_ALLOW_FALLBACK=ON \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
    -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_SDL2=OFF -DWHISPER_CURL=OFF >/dev/null
cmake --build "$SRC/build" --config Release -j "$(sysctl -n hw.ncpu)" --target whisper-server whisper-cli >/dev/null

mkdir -p "$OUT/bin"
cp "$SRC/build/bin/whisper-server" "$SRC/build/bin/whisper-cli" "$OUT/bin/"
# Local symbols are only for debugging; dropping them makes the download smaller.
strip -x "$OUT"/bin/*
echo "$VERSION" >"$OUT/VERSION"

# Shipped inside the app, they may only use what every Mac has.
for bin in "$OUT"/bin/*; do
    if otool -L "$bin" | tail -n +2 | grep -v -E '^\s+(/System/Library/|/usr/lib/)'; then
        echo "$bin links something outside macOS (above); it would not run on other Macs." >&2
        exit 1
    fi
done
otool -L "$OUT/bin/whisper-server" | grep -q CoreML.framework || { echo "whisper-server was built without Core ML" >&2; exit 1; }
echo "Built whisper.cpp $VERSION with Core ML and Metal in $OUT/bin"
