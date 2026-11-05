#!/bin/zsh
# Builds the release app, signs it with your Developer ID, notarizes it with Apple, and makes the .dmg you sell.
#
# One-time setup (needs a paid Apple Developer account):
#   1. In Xcode or developer.apple.com create a "Developer ID Application" certificate and install it in your Keychain.
#   2. Store notarization credentials once:
#        xcrun notarytool store-credentials everyday-notary --apple-id YOU@EXAMPLE.COM --team-id TEAMID --password APP-SPECIFIC-PASSWORD
#   3. Export:
#        export DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
#        export NOTARY_PROFILE=everyday-notary        # optional, this is the default
#
# Then:  ./Scripts/release.sh 0.2.0
#
# With no DEVELOPER_ID it still builds an unsigned (ad-hoc) dmg so you can test the packaging; macOS will warn when it is opened.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${1:?usage: Scripts/release.sh VERSION   e.g. 0.2.0}
PROFILE=${NOTARY_PROFILE:-everyday-notary}
APP=build/everyday.app
DMG=build/everyday-$VERSION.dmg
ENT=Resources/everyday.entitlements

echo "▸ Checks"
CHECK_LOG=$(mktemp)
# Build and run the current checks together; never fall back to an old executable after a build failure.
if ! swift run EverydayChecks >"$CHECK_LOG" 2>&1 || ! tail -1 "$CHECK_LOG" | grep -qx "ALL CHECKS PASSED"; then
  cat "$CHECK_LOG"
  rm -f "$CHECK_LOG"
  echo "Checks failed; not releasing."
  exit 1
fi
tail -1 "$CHECK_LOG"
rm -f "$CHECK_LOG"

echo "▸ Build $VERSION"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M)" Resources/Info.plist
./Scripts/bundle.sh release

if [ -n "${DEVELOPER_ID:-}" ]; then
  echo "▸ Sign (hardened runtime) as $DEVELOPER_ID"
  # The widget extension keeps its own sandbox entitlements, so sign it first and the app without --deep.
  codesign --force --options runtime --timestamp --entitlements Resources/widgets.entitlements --sign "$DEVELOPER_ID" $APP/Contents/PlugIns/EverydayWidgets.appex
  codesign --force --options runtime --timestamp --entitlements $ENT --sign "$DEVELOPER_ID" $APP
  codesign --verify --deep --strict --verbose=2 $APP
else
  echo "▸ No DEVELOPER_ID set: leaving the ad-hoc signature (test build only)"
fi

echo "▸ Make dmg"
# A laid-out window: paper background with the wordmark and an arrow, app on the left, Applications on the right.
rm -rf build/dmg "$DMG" build/rw.dmg; mkdir -p build/dmg/.background
cp -R $APP build/dmg/everyday.app
ln -s /Applications build/dmg/Applications
tiffutil -cathidpicheck Resources/dmg/background.png Resources/dmg/background@2x.png -out build/dmg/.background/background.tiff >/dev/null
hdiutil create -volname "everyday." -srcfolder build/dmg -ov -format UDRW -fs HFS+ build/rw.dmg >/dev/null
DEV=$(hdiutil attach -readwrite -noverify -noautoopen build/rw.dmg | awk '/Apple_HFS/ {print $1}')
sleep 1
osascript <<'AS' || echo "  (Finder layout skipped: allow Terminal to control Finder for the laid-out window)"
tell application "Finder"
  tell disk "everyday."
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 840, 562}
    set o to the icon view options of container window
    set arrangement of o to not arranged
    set icon size of o to 96
    set text size of o to 13
    set background picture of o to file ".background:background.tiff"
    set position of item "everyday.app" of container window to {170, 215}
    set position of item "Applications" of container window to {470, 215}
    update without registering applications
    delay 1
    close
  end tell
end tell
AS
sync; hdiutil detach "$DEV" -quiet || hdiutil detach "$DEV" -force -quiet
hdiutil convert build/rw.dmg -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f build/rw.dmg

if [ -n "${DEVELOPER_ID:-}" ]; then
  codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"
  echo "▸ Notarize (this takes a few minutes)"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG" || true
fi

SUM=$(shasum -a 256 "$DMG" | awk '{print $1}')
echo "$SUM  $(basename $DMG)" > "$DMG.sha256"
# Point the in-app update notice at this version.
python3 - "$VERSION" <<'PY'
import json, sys
p = "site/version.json"
d = json.load(open(p)); d["version"] = sys.argv[1]
json.dump(d, open(p, "w"), indent=2); open(p, "a").write("\n")
PY
echo "✓ $DMG  (sha256 $SUM)"
echo "  Attach it to a GitHub release (gh release create v$VERSION \"$DMG\"), then deploy site/ so version.json goes live."
