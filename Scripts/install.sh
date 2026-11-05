#!/bin/zsh
# Installs the current build as a stable copy in ~/Applications. Run this only when you want to update the app you use every day.
# Rebuilding changes the code signature, so macOS asks for Keychain access again after each install: press "Always Allow" once.
set -euo pipefail
cd "$(dirname "$0")/.."
# Always rebuild: copying a stale bundle silently installed old code before.
./Scripts/bundle.sh release
mkdir -p ~/Applications
rm -rf ~/Applications/everyday.app
cp -R build/everyday.app ~/Applications/everyday.app
echo "Installed ~/Applications/everyday.app"
