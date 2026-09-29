#!/bin/bash
# Builds the plugin bundle into build/com.t01ik.macoscontrols.sdPlugin (universal: Apple Silicon + Intel).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/com.t01ik.macoscontrols.sdPlugin"
cd "$ROOT"

echo "→ Compiling plugin"
swift build -c release --arch arm64 --arch x86_64
BINARY="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/MacControls"

rm -rf "$OUT"
mkdir -p "$OUT"
cp "$BINARY" "$OUT/MacControls"

echo "→ Compiling now-playing helper"
clang -O2 -fobjc-arc -arch arm64 -arch x86_64 -mmacosx-version-min=13.0 -dynamiclib \
	-framework Foundation -framework AppKit -framework ImageIO \
	Helpers/NowPlaying/nowplaying.m -o "$OUT/libnowplaying.dylib"
cp Helpers/NowPlaying/nowplaying.pl "$OUT/"

echo "→ Copying resources (manifest, property inspectors, dial layouts)"
cp Resources/manifest.json "$OUT/"
cp -R Resources/pi "$OUT/pi"
cp -R Resources/layouts "$OUT/layouts"

echo "→ Rendering icons"
"$OUT/MacControls" --generate-icons "$OUT"

codesign --force --sign - "$OUT/libnowplaying.dylib" "$OUT/MacControls" 2>/dev/null
echo "✓ Built $OUT"
