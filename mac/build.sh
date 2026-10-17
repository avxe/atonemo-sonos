#!/bin/sh
# Builds "build/Atonemo Sonos.app" (Apple silicon + Intel) and a zip of it.
set -eu
cd "$(dirname "$0")"
flags="-c release --arch arm64 --arch x86_64"
swift build $flags
app="build/Atonemo Sonos.app"
rm -rf build
mkdir -p "$app/Contents/MacOS"
cp "$(swift build $flags --show-bin-path)/AtonemoSonos" "$app/Contents/MacOS/"
cp Info.plist "$app/Contents/"
codesign --force --sign - "$app"
ditto -c -k --norsrc --noextattr --keepParent "$app" build/AtonemoSonos.zip  # stays valid after any unzip
echo "Built $app"
