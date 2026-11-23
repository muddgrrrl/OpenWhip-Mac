#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/openwhip-build.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
app="$scratch/root/OpenWhip.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" dist
cp Info.plist "$app/Contents/Info.plist"
python3 Sources/make-sound.py "$app/Contents/Resources/Crack.wav"

iconset="$scratch/OpenWhipIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    icon_name="icon_${size}x${size}"
    retina_size=$((size * 2))
    sips -z "$size" "$size" Assets/OpenWhipIcon.png --out "$iconset/$icon_name.png" >/dev/null
    sips -z "$retina_size" "$retina_size" Assets/OpenWhipIcon.png \
        --out "$iconset/${icon_name}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/OpenWhipIcon.icns"

for architecture in arm64 x86_64; do
    swiftc -O -whole-module-optimization -target "$architecture-apple-macos13" Sources/*.swift -o "$scratch/OpenWhip-$architecture"
done
lipo -create "$scratch/OpenWhip-arm64" "$scratch/OpenWhip-x86_64" -output "$app/Contents/MacOS/OpenWhip"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
"$app/Contents/MacOS/OpenWhip" --self-test

pkgbuild --root "$scratch/root" --install-location /Applications \
    --identifier local.openwhip.mac.pkg --version 1.6 "$scratch/OpenWhip.pkg"
ditto "$app" dist/OpenWhip.app
mv -f "$scratch/OpenWhip.pkg" dist/OpenWhip.pkg
