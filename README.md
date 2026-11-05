# everyday.

A native macOS app (SwiftUI) that brings AI-sorted Gmail, personalised news, tasks and a daily briefing into one calm, serif-typeset, dark-first window. Local-first: no servers, no analytics, no accounts.

## What it does
- **Mail:** any IMAP account with an app password (Gmail, iCloud, Fastmail, Yahoo, custom), or the Gmail API with your own Google client. AI sorts and summarises; repeated automated mail is bundled with a source list; archive, trash and mark-read are instant. Sending, archiving and deleting only happen when you press a button.
- **Briefing:** written each morning and streamed as it's written, with colour highlights for skimming. Settings → Briefing controls what it includes, the topics to hide, and standing instructions in your own words. "That was me" removes things and rewrites it.
- **News:** your sources, deduplicated and ranked by what you swipe, read and save. OPML import and export.
- **Tasks:** quick add understands "pay rent friday 5pm high" and repeats ("every friday", "monthly"); suggestions from mail (with or without an AI key); delete one, completed, or all.
- **Mail extras:** snooze with a reminder task, VIP senders, a reviewed bulk-archive list, an unsubscribe helper that only opens the sender's own page after you approve, attachment Quick Look, and a 10-second undo after you send.
- **Assistant:** answers cite the mail and stories they used, as buttons that open them.
- **Morning briefing notification** at the hour you choose, and a settings search.
- **Voice:** natural speech through Gemini (male voices by default, cached on disk), or the best voice installed on the Mac.
- **Private:** no servers, no analytics. Keys and passwords live in the Keychain.

## Build and run (no Xcode needed, Command Line Tools are enough)

```bash
./Scripts/bundle.sh          # builds and assembles build/everyday.app (ad-hoc signed)
open build/everyday.app
swift run EverydayChecks     # 90+ self-checks: DB, parsers, IMAP against a scripted server, bundling, rules, live news and weather
```

Notes: `@State` is a macro in the macOS 27 SDK whose plugin ships only with Xcode, so views use the `Local` wrapper in `Theme.swift`. XCTest and Swift Testing also need Xcode, hence the `EverydayChecks` executable.

## What you need to supply

| Feature | Credential | Where |
|---|---|---|
| AI (default Gemini) | API key from aistudio.google.com/apikey | Settings → AI provider (stored in Keychain) |
| Gmail | Your own Google Cloud OAuth client (Desktop app type) with the Gmail API enabled: client ID and secret | Settings → Accounts |
| Calendar, Reminders | macOS permission prompts | Allow when asked |
| Notifications | macOS permission prompt | Allow when asked |

Gmail scopes: `gmail.modify`, `gmail.compose` (restricted scopes). Keep the OAuth consent screen in production (unverified) to avoid 7-day token expiry; ≤100 users without Google verification.

## Safety model
AI code (`Intelligence`, `AIService`) only returns text/JSON. Mail writes (send, archive, trash, mark read, save draft) exist only on `MailService` and require a `UserApproval`, which the UI creates from explicit button presses (send additionally shows a review sheet).

## Dev aid
`EVERYDAY_SNAPSHOT_DIR=/tmp/shots open --env EVERYDAY_SNAPSHOT_DIR=/tmp/shots build/everyday.app` writes a PNG per screen and quits.

## Live checks (optional, need your own credentials)
```bash
GEMINI_API_KEY=...  swift run EverydayChecks                  # AI: triage, summaries, highlights, speech
IMAP_EMAIL=you@gmail.com IMAP_PASSWORD="app password" swift run EverydayChecks   # read-only IMAP
GOOGLE_CLIENT_ID=... GOOGLE_CLIENT_SECRET=... swift run EverydayChecks            # read-only Gmail API
```

## Development without disturbing your daily copy
`./Scripts/dev.sh` runs the build with its own database, preferences and Keychain names (`EVERYDAY_DEV=1`). `./Scripts/seed-dev.py` fills that database with invented mail for checking screens. `./Scripts/install.sh` updates `~/Applications/everyday.app` (macOS asks for Keychain access again after each install, because the ad-hoc signature changes).

## Known limits
- Unsigned (no Apple Developer ID): Gatekeeper needs Open Anyway; Keychain asks again after each update.
- Outlook/Hotmail: Microsoft no longer allows app passwords for IMAP.
- Mail refreshes every 15 minutes; there's no push (IDLE) yet.
- Not yet built: Windows, IDLE push, Developer ID signing and notarisation.
- An unsent reply is held in memory for 10 seconds; quitting the app in that window cancels it.
- Attachments are listed for mail synced after this version; older stored mail needs a re-sync.

## Releasing (for the maintainer)
`./Scripts/release.sh 0.2.0` runs the checks, builds the release app, makes `build/everyday-0.2.0.dmg` with a SHA-256 file, and bumps `site/version.json` so the in-app update notice sees it. Set `DEVELOPER_ID` (and store notarization credentials once, see the top of the script) and the same command also signs with the hardened runtime and notarizes and staples the dmg, so Gatekeeper opens it with no warning. Without them it makes an unsigned test dmg.
SMTP sending, IMAP archive/trash/draft and Gmail are all checked against scripted local servers; the live-account checks stay opt-in through environment variables.
