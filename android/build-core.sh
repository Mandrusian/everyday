#!/bin/zsh
# Builds the Rust core for Android into app/src/main/jniLibs (arm64 phones and x86_64 emulators).
set -e
cd "$(dirname "$0")/../windows"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$HOME/Library/Android/sdk/ndk/28.2.13676358}"
cargo ndk -t arm64-v8a -t x86_64 -P 26 -o ../android/app/src/main/jniLibs build -p everyday-mobile --release
