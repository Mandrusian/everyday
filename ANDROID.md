# everyday. for Android

Status: implemented in `android/` (Jetpack Compose + Glance + WorkManager) over the Rust core in `windows/core` and `windows/mobile`. Needs Android NDK / SDK to compile the APK locally and a Google Play developer account (or signed APK release) for distribution.

## Shape
- **Core:** `windows/core` and `windows/mobile` (Rust), shared with Windows. Exposed to Kotlin through a single JNI command bridge (`Core.kt` / `windows/mobile/src/lib.rs`), built per ABI (`arm64-v8a`, `x86_64`) with `cargo ndk` via `android/build-core.sh` into `android/app/src/main/jniLibs/`.
- **UI:** Kotlin and Jetpack Compose in `android/app/src/main/java/app/everyday/android/` (`Today.kt`, `Inbox.kt`, `Thread.kt`, `News.kt`, `Tasks.kt`, `Ask.kt`, `Onboarding.kt`, `Settings.kt`), using the same paper, ink and clay design as the Mac app and the site.
- **Secrets:** an Android Keystore-backed `Secrets` store (`Secrets.kt`) passed into the core per command (`_secrets`) and updated from the returned diff. Mail passwords and AI keys never leave Keystore-encrypted storage.
- **Background work:** WorkManager (`Morning.kt`) runs mail sync, news refresh and the morning briefing check; a notification announces the briefing at the chosen hour.
- **Widgets:** Jetpack Glance home-screen widgets (`Widgets.kt`: Calendar/Month, Your day/Brief, Needs you, Tasks) fed from a local `WidgetSnapshot`.
- **Voice:** Gemini natural voice through the core (cached on disk) played with Android `MediaPlayer`.
- **Wi-Fi sync:** `SyncLink` (`Sync.kt`) holds a multicast lock and syncs tasks, topics and setup bundles over mDNS (`windows/mobile/src/synchost.rs`).

## Building
1. Build the Rust `.so` libraries (requires `cargo-ndk` and `ANDROID_NDK_HOME`):
   ```bash
   ./android/build-core.sh
   ```
2. Build the Android app with Gradle (requires Android SDK platforms/build-tools):
   ```bash
   cd android && ./gradlew assembleDebug
   ```
3. Release signing (`android/release.keystore`, `android/keystore.properties`, gitignored) and Play Store / GitHub Releases APK publishing remain before public release.

## Safety invariant (unchanged)
The AI only returns text or JSON. Sending, archiving and deleting mail happen only from a button the user pressed.
