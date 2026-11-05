#!/bin/zsh
# Runs the build with its own data, preferences and Keychain names, so development never touches the app you use and never triggers its Keychain prompts.
cd "$(dirname "$0")/.."
./Scripts/bundle.sh && EVERYDAY_DEV=1 build/everyday.app/Contents/MacOS/Everyday
