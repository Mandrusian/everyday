# everyday. for Android: plan

Status: not started. The groundwork is in place: the Rust core in `windows/core` has no desktop-only code on Android (the secret store and TLS are switched per platform in `Cargo.toml` and `secrets.rs`), so the same tested logic can run on a phone.

## Shape
- **Core:** `windows/core` (Rust), shared with Windows. Exposed to Kotlin through [UniFFI](https://mozilla.github.io/uniffi-rs/), built per ABI (`aarch64-linux-android`, `x86_64-linux-android`) with `cargo ndk` into `jniLibs/`.
- **UI:** Kotlin and Jetpack Compose, using the same paper, ink and clay design as the Mac app and the site. Today, Inbox, News with the swipe deck, Tasks, Ask everyday., Settings.
- **Secrets:** an Android Keystore-backed `SecretStore` written in Kotlin and passed into the core. Mail passwords and AI keys never leave it.
- **Background work:** WorkManager runs mail sync, the news refresh and the morning briefing; a notification announces the briefing at the chosen hour.
- **Widgets:** Jetpack Glance versions of the Mac widgets (Clock, Weather, Up next, Brief, Quote of the day, Needs you, Top news, Tasks), fed from the same snapshot shape as `WidgetSnapshot`.
- **Voice:** Gemini natural voice through the core (already cached on disk), falling back to Android TextToSpeech.

## Order
1. Generate UniFFI bindings for the core's public API; build the `.so` files in CI (`ubuntu-latest` with the NDK).
2. Keystore `SecretStore`, storage path in the app's private files directory.
3. Setup wizard and Inbox (IMAP and Gmail with an app password), then Today and the briefing.
4. News and the swipe deck, Tasks, Ask everyday.
5. Glance widgets, notifications, voice.
6. Play Store listing (needs a Google Play developer account) or a signed APK on GitHub Releases.

## Safety invariant (unchanged)
The AI only returns text or JSON. Sending, archiving and deleting mail happen only from a button the user pressed.
