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
swift build --product EverydayChecks 2>&1 | grep -E "error" && exit 1 || true
./.build/out/Products/Debug/EverydayChecks 2>&1 | tail -1 | grep -q "ALL CHECKS PASSED" || { echo "Checks failed; not releasing."; exit 1; }

echo "▸ Build $VERSION"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M)" Resources/Info.plist
./Scripts/bundle.sh release

if [ -n "${DEVELOPER_ID:-}" ]; then
  echo "▸ Sign (hardened runtime) as $DEVELOPER_ID"
  codesign --force --deep --options runtime --timestamp --entitlements $ENT --sign "$DEVELOPER_ID" $APP
  codesign --verify --deep --strict --verbose=2 $APP
else
  echo "▸ No DEVELOPER_ID set: leaving the ad-hoc signature (test build only)"
fi

echo "▸ Make dmg"
rm -rf build/dmg "$DMG"; mkdir -p build/dmg
cp -R $APP build/dmg/everyday.app
ln -s /Applications build/dmg/Applications
hdiutil create -volname "everyday." -srcfolder build/dmg -ov -format UDZO "$DMG" >/dev/null

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
