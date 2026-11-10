#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
./build.sh
app="$PWD/dist/Melodics Maschine Bridge.app"
resources="$app/Contents/Resources"
mkdir -p "$app/Contents/MacOS" "$resources"
cp macapp/Info.plist "$app/Contents/"
cp ipc_bridge.py maschine_profile_probe.py install_4x4_profile.py launchpad-probe ni-led-helper "$resources/"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
xcrun swiftc -module-cache-path "$tmp/cache" macapp/App.swift -o "$app/Contents/MacOS/MelodicsMaschineBridge"
mkdir "$tmp/Bridge.iconset"
xcrun swift -module-cache-path "$tmp/cache" macapp/Icon.swift "$tmp/Bridge.iconset"
python3 macapp/make-icns.py "$tmp/Bridge.iconset" "$resources/Bridge.icns"
cp "$tmp/Bridge.iconset/icon_256x256.png" "dist/Bridge Icon.png"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
