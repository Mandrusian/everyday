# everyday. for Windows: plan

Status: started. `windows/` holds a Rust workspace: `core/` (the ported logic, 37 tests passing on macOS) and `app/` (a Tauri 2 shell that compiles and shows a Today preview using the core). It has not been run on a Windows machine yet.

| Step | State |
|---|---|
| 1 Storage (SQLite, old data keeps loading), secrets (Credential Manager) | done, tested |
| 2 Mail: MIME, attachments, unsubscribe, handled/snooze/VIP/bundles, IMAP, SMTP, sync | done, tested against scripted IMAP and SMTP servers |
| 3 AI: Gemini/Claude/OpenAI/local, triage, briefing (handled senders never appear), situational reply buttons with "That was me" guaranteed, assistant with citations | done, tested |
| 4 Quick-add, repeats, tasks, update notice, morning schedule | done, tested |
| 5 News: feeds, promo filter, muted topics, clustering, ranking, interest learning (swipe/read/save, 45-day decay) | done, tested |
| 6 Voice: Gemini natural voice (cached on disk), falls back to the voices installed on the PC | done (request/audio/WAV/chunking tested); playback untested on Windows |
| 7 UI: setup wizard, Today, Inbox, News with swipe deck, Tasks, Ask everyday., Settings, morning notification | written and compiles; never run on Windows |
| 8 Installer and signing | Tauri NSIS/MSI configured; signing needs a Windows code-signing certificate |

Calendar: read-only through a secret iCal (.ics) link from Google, Outlook or iCloud (events, all-day, repeats, cancellations), shown under Today and fed to the briefing. Not ported: two-way sync with Apple/Windows calendars and Apple Reminders (tasks stay in the app's own list). 96 core tests pass on macOS.

Run the tests with `cd windows && cargo test -p everyday-core`. Run the preview on Windows with `cd windows/app && cargo tauri dev`.

## Why the Mac code can't be reused directly
The Mac app is SwiftUI plus Apple frameworks (Network.framework for IMAP, Keychain, EventKit, AVFoundation, AppKit). Swift runs on Windows, but SwiftUI does not. Everything under `Sources/Everyday/` has to be rebuilt; the *logic* in `Sources/EverydayCore/` has to be ported, with the Mac code as the specification and its checks as the test suite.

## Recommended stack
Tauri 2 (Rust core, web UI). Reasons: small installer (about 10 MB), native Windows Credential Manager for secrets, SQLite available, and the UI can reuse the design already built for the website (cream/dark palette, serif headlines, same components).

## What to port, in order
1. **Storage and secrets:** SQLite with the same document layout (`docs(kind,id,sort,json)`), Windows Credential Manager for keys and mail passwords.
2. **Mail:** IMAP over TLS (`async-imap`), MIME parsing (`mail-parser`), SMTP (`lettre`). Port the scripted-server checks from `Sources/EverydayChecks/FakeImap.swift` first, then the client.
3. **AI layer:** the provider-agnostic client and every prompt in `Intelligence.swift`, kept word for word, including the "mail is untrusted data" rules. Port the model discovery and quota handling.
4. **Triage, bundling, handled/snooze/VIP rules, quick-add parser, repeat rules, citations:** pure logic with tests ported one for one from `EverydayChecks/main.swift`.
5. **News:** RSS/Atom parser, clustering, interest model, extractor.
6. **UI:** Today, Inbox, News, Tasks, Settings, onboarding, in the order the Mac app was built. Notifications through the Windows toast API; speech through Windows neural voices and the Gemini voice option.
7. **Packaging:** MSIX or signed installer (needs a code-signing certificate, the Windows equivalent of Developer ID), with the same update-notice mechanism reading `site/version.json`.

## Safety invariant to carry over unchanged
The AI only returns text or JSON. Sending, archiving and deleting mail happen only from a button the user pressed. Handled, snooze, VIP and rules stay local.

## Rough size
About the same as the Mac app's core plus UI: several weeks of focused work, so it is a separate project after the Mac release, as planned.
