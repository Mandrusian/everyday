#!/bin/zsh
# Builds everyday. and assembles a signed .app bundle in ./build (no Xcode required).
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${1:-debug}
swift build -c $CONFIG --product Everyday 2>&1 | grep -E "error|Compiling|Build" | tail -5
BIN=$(swift build -c $CONFIG --show-bin-path)/Everyday
APP=build/everyday.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp $BIN $APP/Contents/MacOS/Everyday
cp Resources/Info.plist $APP/Contents/Info.plist
if [ ! -f build/AppIcon.icns ]; then
  mkdir -p build/icon.iconset
  swiftc -o build/make-icon Scripts/make-icon.swift 2>/dev/null && ./build/make-icon build/icon-1024.png
  for s in 16 32 64 128 256 512; do
    sips -z $s $s build/icon-1024.png --out build/icon.iconset/icon_${s}x${s}.png >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon-1024.png --out build/icon.iconset/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns build/icon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns $APP/Contents/Resources/AppIcon.icns
codesign --force --deep --sign - $APP
echo "Built $APP"
