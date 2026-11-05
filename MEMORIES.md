# Memories (keep across compaction)

## State (6 November 2026)
- Local commits not pushed: 2b0443e (Mac widgets), b58097a and 58e204a (Android), 97003bf and 3583dfb (Windows Slint and interests). The user approved the work but said it "needs much more polish". Ask before pushing.
- Three apps, one ecosystem (the user's word):
  - **Mac:** SwiftPM.
  - **Android:** Kotlin and Compose.
  - **Windows:** Slint.
  - **Shared Rust layer:** Android and Windows share the command layer `windows/mobile` (`everyday_mobile::run(cmd, args, &dyn SecretStore)` plus `call_json` for JNI).
  - **Not yet shared:** the Mac app still uses its own Swift core.

## Windows (Slint, `windows/desktop`)
- **Code:** UI in `ui/app.slint`, glue in `src/main.rs`. Icons are SVGs in `ui/icons`, and Source Serif 4 is bundled. Binary `target/release/everyday`.
- **Dev env vars:** `EVERYDAY_DATA` (data folder), `EVERYDAY_SKIP_SETUP`, `EVERYDAY_PAGE`. On a Mac the data goes in `~/Library/Application Support/everyday-windows-preview`.
- **Slint gotchas:**
  - Wrapped text under-reports its height, so use `Para`, which estimates it. Pass `breaks` as the count of newlines.
  - Wrappers need explicit min and preferred heights (see `Appear`).
  - `row` is a reserved property name.
  - `for` can't nest `if`, so pre-chunk rows in Rust (`TopicRow`).
  - Components must be defined before they're used.
  - `upgrade_in_event_loop` needs `Send`, so the `bg()` helper uses a thread-local ticket map.
- **CI:** `.github/workflows/windows.yml` now runs `cargo packager`, but it has never run.
- **The old Tauri app** in `windows/app` is still in the repo, unused.
- **Known polish gaps:**
  - briefing highlights show as plain text (no rich text);
  - line spacing is tight;
  - `EVERYDAY_PAGE` is sometimes ignored;
  - no Windows notifications;
  - Slint `Text` has no line-height control in 1.18 (line spacing stays tight);
  - the user wants much more polish overall.

## Android (`android/`)
- **Core library:** build `libeveryday_mobile.so` with `android/build-core.sh` (NDK 28.2, cargo-ndk). `jniLibs` is git-ignored.
- **Phone:** a OnePlus PKJ110 on wireless adb. ColorOS needs a tap on **Install** on the phone for each `adb install`.
- **Secrets:** an Android Keystore AES-GCM key, passed to the core in `args._secrets` on each call.
- **Code:** Model.kt holds the state; screens are Today, Inbox, Thread, News, Tasks, Ask, Settings and Onboarding. Morning.kt is the WorkManager job.
- **To do:**
  - Glance widgets;
  - highlight colours use `Format.skim`.

- Asks for notification permission on launch (done 6 Nov).
- Teach me deck on Windows: cards fly off and can be dragged (done 6 Nov).

## Mac
- **Bug (6 Nov):** Mac widgets stopped working after the Liquid Glass default and clear background change (7a3cd24). The user parked this to do sync first.
- **Widgets:** 15 widgets, a Flat or Liquid Glass look, and Custom 1–3 built in Settings → Widgets.
- **AppIntents widget configuration is impossible:** it needs Xcode's metadata processor, and the build uses SwiftPM.
- **Interests:** onboarding already has topics and the swipe deck, and Settings → Interests can retrain.

## User preferences
- **Name and look:**
  - The name is "everyday." with the period.
  - Claude colours (warm paper, ink, clay), flat (no gradients), serif headlines, minimal.
- **Polish and animation:**
  - Polish above all.
  - Wants animations everywhere: in onboarding and on every screen.
  - Wants special mobile touches (haptics, swipes).
  - All platforms should have the same features as the Mac app: tabbed settings like the Mac, a sidebar that collapses to icons, interests onboarding with the swipe deck, and retraining.
- **Security mail:** "That was me" shows up front only for account-security mail.
- **Free:** free, GPL-3.0, no payments anywhere.
- **Working style:**
  - Approve plans before big features; wants to test the app themselves before approving.
  - Uses yabai.
  - Ultracave (terse) reply mode is on.
- **Secrets:** never handle tokens myself; `.env` holds `CF_API_TOKEN`.
- **Demo contact:** Oscar Fox (never Dana).

## Facts
- **Links:** repo github.com/Mandrusian/everyday; site everyday.mandrusia.tech; release v0.1.0 (the old Tauri build).
- **NOTES.md:** add a dated Claude section each round. Not yet updated for the widgets, Android and Slint work.
- **Mac build:** `./Scripts/bundle.sh`, `./Scripts/install.sh`, `swift run EverydayChecks`.
- **Rust:** `~/.cargo/bin/cargo`. Tests: `cargo test -p everyday-core -p everyday-mobile -p everyday-desktop` from `windows/`.
- **macOS logs:** use `/usr/bin/log` (zsh has a `log` builtin).
- **Open issue:** thread IDs are not namespaced by account (from Codex's review).
