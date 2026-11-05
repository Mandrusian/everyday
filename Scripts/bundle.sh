#!/bin/zsh
# Builds everyday. and assembles a signed .app bundle in ./build (no Xcode required).
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${1:-debug}
swift build -c $CONFIG --product Everyday 2>&1 | grep -E "error|Compiling|Build" | tail -5
swift build -c $CONFIG --product EverydayWidgets 2>&1 | grep -E "error" | tail -5 || true
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
# Widget extension: an .appex inside the app, sandboxed and signed on its own before the app is signed.
APPEX=$APP/Contents/PlugIns/EverydayWidgets.appex
mkdir -p $APPEX/Contents/MacOS
cp $(swift build -c $CONFIG --show-bin-path)/EverydayWidgets $APPEX/Contents/MacOS/EverydayWidgets
cp Resources/Widgets-Info.plist $APPEX/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)" $APPEX/Contents/Info.plist
codesign --force --sign - --entitlements Resources/widgets.entitlements $APPEX
codesign --force --sign - $APP
echo "Built $APP"
