# everyday. — release roadmap

Goal: a free, open-source Mac app other people can download or build and set up in under five minutes.

## v1.0 scope (Mac only)

Ship: Today dashboard, Inbox (IMAP), News + reader, Tasks, Assistant, Settings, onboarding, menu bar item.
Not in v1: Windows, iCloud sync, Gmail API for everyone (kept as an advanced option), widgets, notarization.

## Milestones

### M1 — Friendly mail (IMAP)
- IMAP client over TLS (Network.framework): LOGIN, LIST, SELECT, UID SEARCH, UID FETCH, STORE, COPY/MOVE, APPEND (drafts), IDLE or 5-minute polling.
- SMTP submit (TLS) for approved sends.
- Provider presets with auto-fill: Gmail, iCloud, Outlook/Hotmail, Fastmail, Yahoo, custom. Domain-based discovery.
- First-run wizard: pick provider → show the exact 3 steps to make an app password (with a button that opens the right page) → paste → test connection → first sync.
- MIME parser: multipart, quoted-printable, base64, charsets, HTML to text, attachment list, List-Unsubscribe header.
- Gmail API stays as "Advanced: sign in with your own Google client".
- Local-only triage labels (already built); never modify the server except on approval.
- Checks: parser fixtures; live IMAP check gated on env vars (like the Gmail check); a fake IMAP server for tests.

### M2 — New features (useful, small)
Mail
- Unsubscribe helper: one click from a newsletter, shows what it will do, runs only after approval.
- Bulk review: "Archive these 23 promotions?" as a reviewable list, never silent.
- Reply-later: snooze a thread to a time; it returns to the top and becomes a task.
- VIP senders and sender rules (always newsletter / always important), stored locally.
- Keyboard: j/k move, e archive, r reply, # trash (each still confirms), / search, ⌘Return send review.
- Undo for archive; 10-second delay before a send completes.
- Attachment list with Quick Look.
News
- OPML import and export; mute keywords; "more/less from this source".
- Offline reading list.
Tasks
- Natural quick-add: "pay rent friday 5pm high" parsed on device.
- Recurring tasks; today list in the menu bar.
Assistant
- Answers cite the email or story they used, clickable.
- "Ask about selection" from any text in the reader or a thread.
Briefing
- Delivered as a notification at the chosen time.
Listen (text to speech) — three tiers, user picks in Settings
1. Default: macOS voices through `AVSpeechSynthesizer`, auto-picking the best installed voice (Premium or Enhanced, Siri-quality where present; Personal Voice if the user made one). Free, offline, no setup. Replaces the older, robotic `NSSpeechSynthesizer` currently used. Settings shows the voice list with a preview and a link to download Premium voices.
2. Cloud, opt-in: Gemini speech models through the user's own key (the model list already includes `gemini-*-flash-tts`). Natural, but sends the text to Google and uses quota; shown in the AI activity log like any request.
3. Local neural, optional download: a small open model (Piper, MIT, about 20–60 MB per voice, or Kokoro-82M, Apache-2.0) run on device. Larger than the app, so it is a one-time download inside Settings, not bundled. Needs a spike first to check licence, size, latency and Swift integration.
Player: sentence-by-sentence highlighting in the reader, play/pause, speed, skip, resumes where it stopped, plays while the app is in the background.

### M3 — Polish
Visual and motion
- One spacing and type scale used everywhere (sans UI, serif only for reading); audit light mode.
- Much more motion, all subtle and fast (120–300 ms springs), all disabled by Reduce Motion:
  - sidebar selection slides between items; screens cross-fade and slide a few points
  - lists animate rows in, out and re-ordering (archive slides away, new mail eases in); swipe card physics and stacking already started, add haptic-style settle
  - skeleton shimmer while loading; progress for sync and triage; number changes roll
  - briefing text streams in word by word; summary and reply drafts stream into place
  - task completion: check draws, row collapses; suggestion accept flies into the list
  - assistant panel slides in; messages rise in; typing indicator
  - matched-geometry transition from a story row into the reader
  - button press, hover and focus states everywhere; toasts slide and auto-dismiss
- Animations are measured: 60 fps on the largest list, no layout jank.
- Final app icon, DMG background, menu bar icon.
Reliability
- Offline mode with clear states; every error has a plain next step; no raw errors in the UI.
- Database migrations versioned; export all data as JSON; backup before upgrade.
- Large inbox performance: paging, background parsing, memory check with 10k messages.
- Battery: refresh every 15 minutes only while the app is open; no background daemon.
Accessibility
- VoiceOver labels and rotor order on every screen; keyboard-only path through the app; contrast check on both themes; text size follows system setting.
Help
- In-app help for app passwords and privacy; "What does everyday. send to the AI?" always one click away.

### M4 — Ship
Repository
- LICENSE (GPL-3.0), README with 3-command build, CONTRIBUTING, SECURITY, privacy statement, no secrets or personal data in history.
- `Scripts/release.sh`: universal binary (arm64 + x86_64), bundle, ad-hoc sign, DMG, SHA-256.
Site (everyday.mandrusia.tech)
- One page: what it is, screenshots, download, privacy, build-from-source link, Open Anyway instructions with screenshots, privacy policy.
Distribution
- Free. The signed DMG is attached to GitHub Releases; the site's download button points at the latest release.
Updates
- Sparkle appcast on the site; EdDSA signing key kept offline. Works without an Apple account.
Support
- Public issue tracker; an in-app "Copy diagnostics" button (no mail or personal data).

## Quality gates before anyone pays
1. `EverydayChecks` all green, including live IMAP and Gmail checks.
2. Fresh-Mac test: install the DMG on a Mac that has never seen the project; setup to first briefing in under five minutes.
3. Three real users complete onboarding without help.
4. Manual QA list passes (every screen, light and dark, small window, VoiceOver, offline).
5. Privacy review: network log shows only the providers the user chose.
6. README states plainly what is and is not tested.

## Known limits to state publicly
- Unsigned (no Apple Developer ID): Gatekeeper needs Open Anyway until an account is added.
- macOS only; Windows is a separate project after v1 sells.
- Apple Intelligence on-device model is small; cloud model quality depends on the user's own key and quota.


## Status (November 2026)
Built and checked: IMAP and Gmail API mail, triage, bundles, briefing with highlights and streaming, "That was me" for whole sender groups, snooze, VIP senders, unsubscribe helper, bulk archive review, attachment Quick Look, 10 s undo send, recurring tasks, rule-based task suggestions, assistant citations, morning notification, settings search, skeleton loading, motion polish (Reduce Motion respected), promo-story filter, sync status with retry.

Also built: in-app update notice (reads site/version.json once a day, opens the download page; no silent installs), an automated accessibility-tree audit of every screen (`EVERYDAY_AX_AUDIT=1` with the snapshot tool) with every input, toggle, picker and slider named, and offline neural voices through Apple's Premium/Enhanced voices.

Release tooling is written and tested: `Scripts/release.sh` (checks, build, dmg, checksum, version bump; signing and notarization switch on when `DEVELOPER_ID` is set) and `Resources/everyday.entitlements`. SMTP send, IMAP archive/trash/draft are verified against scripted local servers.

Still needs the owner (these cannot be done without their accounts, money or ears): the Developer ID certificate and notarization credentials (run the script once they exist), Sparkle-style silent updates (needs signing keys from that account), a spoken VoiceOver listen-through, and Windows (`windows/` has the full port: a Rust core with 96 passing tests and a Tauri app with every screen, including calendar through an iCal link; it has not been run on a Windows machine, see WINDOWS.md).
Decided against: a bundled Piper/Kokoro voice. It needs an ONNX runtime and a 20-60 MB model inside a SwiftPM-only build; Apple's on-device Premium voices give the same offline, no-cloud result with no extra dependency.

Verified live on 5 Nov 2026 against a real Gmail account (11,654 messages): IMAP login, sync of 150 messages, quiet incremental sync, and an SMTP message to the owner's own address accepted by the server.
