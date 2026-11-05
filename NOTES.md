# Handoff notes (5 November 2026)

State of everyday. for whoever picks this up next. Read README.md, ROADMAP.md, WINDOWS.md and ANDROID.md for the bigger picture.

## Repo and build
- Repo: github.com/Mandrusian/everyday (public, GPL-3.0). Branch `main`. Opus handoff saved locally as commit `7f7a2c4` and tag `opususagelimit-switchtocodex` (includes the previous uncommitted widget experiments and these notes). This checkpoint has not been pushed.
- Mac app: SwiftPM only, no Xcode. `./Scripts/bundle.sh` builds `build/everyday.app`; `./Scripts/install.sh` copies it to `~/Applications/everyday.app`. Checks: `swift run EverydayChecks` (must end `ALL CHECKS PASSED`; the live Gemini "speech: replay comes from the on-disk cache" check is occasionally flaky, so rerun before chasing it).
- Dev copy with its own data: `./Scripts/dev.sh` (`EVERYDAY_DEV=1`). Screenshots of every screen: `EVERYDAY_DEV=1 EVERYDAY_SNAPSHOT_DIR=/some/dir build/everyday.app/Contents/MacOS/Everyday`.
- Windows: Rust workspace in `windows/` (`cargo test -p everyday-core`, 98 tests after Codex polish). CI in `.github/workflows/windows.yml`; pushing a `v*` tag builds installers and attaches them to a GitHub release. Release `v0.1.0` exists with the `.exe`, `.msi` and SHA256SUMS.
- Website: static `site/`, deployed to GitHub Pages by `.github/workflows/pages.yml`, custom domain everyday.mandrusia.tech (Cloudflare DNS CNAME, done). HTTPS certificate from GitHub was still pending; when issued, tick Enforce HTTPS in repo Settings → Pages.
- Secrets for scripts live in `.env` (git-ignored); template in `.env.example`. `Scripts/cloudflare-dns.sh` manages DNS with `CF_API_TOKEN`.

## Codex

### Widget support fixed (commit `ab94697`)
- Priority: fix widget support; leave the Mac app UI unchanged. Windows improvements are allowed but have not been started in this continuation.
- Root cause confirmed on macOS 27: the SwiftPM executable entered Swift's `_main` directly. `WidgetBundle.main()` then trapped in ExtensionFoundation's `_EXRunningExtension._shared` because the extension runtime had not been initialized.
- `Package.swift` now links the widget with `-e _NSExtensionMain` and `-u _main`. Apple's entry point initializes the extension runtime, then discovers the retained Swift entry through `__swift5_entry`. The app's entry point is unchanged.
- Ad-hoc signing works. A paid certificate, application-identifier entitlement, and extra `EXAppExtensionAttributes` metadata were not needed. Removed the unsuccessful `get-task-allow` experiment. The earlier bundle-struct rename and platform plist keys remain.
- `Scripts/bundle.sh` now fails on widget build errors instead of packaging a stale binary, synchronizes both version fields, and runs `python3 Scripts/check-widgets.py build/everyday.app`.
- The packaging check verifies every binary architecture enters Apple's bootstrap, retains Swift main and its entry metadata, matches app/extension versions, and passes signature verification. A negative-control bundle using the original crashing binary is correctly rejected.
- Validation: debug app bundle and optimized release widget build successfully; `EverydayChecks` ends `ALL CHECKS PASSED` (live account/AI/send checks disabled). On the installed extension, chronod loads descriptors and successfully renders placeholder batches without the bootstrap trap. Apple's WidgetKit Simulator lists all 8 widgets (Clock, Weather, Up next, Brief, Quote of the day, Needs you, Top news, Tasks); Weather's live timeline successfully loads the app's on-disk snapshot rather than sample data, including a reload after installing the optimized release widget.
- Installed testing updates only the widget extension plus the containing app's signature; the main app code is unchanged (confirmed identical after removing signatures from comparison copies). Original installed app backup: `/private/tmp/everyday-opususagelimit-switchtocodex.app` (temporary; the Git tag is the durable source rollback point).
- To rebuild: `./Scripts/bundle.sh`; to verify any assembled app: `python3 Scripts/check-widgets.py /path/to/everyday.app`. After updating an installed extension, register it with `pluginkit -a /path/to/everyday.app/Contents/PlugIns/EverydayWidgets.appex`; restart `chronod` if its old failure is cached.
- Useful diagnostics: `/usr/bin/log show --last 5m --style compact --predicate 'process == "EverydayWidgets"'` and `pluginkit -m -v -i app.everyday.mac.widgets`. Use the full `/usr/bin/log` path because zsh has a `log` builtin.

### Reliability polish and review
- Scope: no Mac UI changes and no visual redesign. Windows core reliability fixes only; the new Mac features still need porting to Windows.
- `windows/core/src/service.rs`: fixed permanent mail gaps after a sync batch exceeded 150 messages. Sync now fetches missing UIDs newest first and backfills remaining gaps on subsequent runs, instead of discarding everything below the highest stored UID.
- `windows/core/src/store.rs`: added an error-propagating ID-only query so sync checks all stored UIDs without loading every stored message body. A UIDVALIDITY change now clears all old mailbox messages rather than only the first 5,000.
- `windows/core/src/mime.rs` and `service.rs`: preserve the message's Date header (including its time-zone offset); use sync time only when the header is absent or invalid. Previously every new message was dated at sync time. This corrects newly fetched mail; existing stored dates are not migrated.
- Regression tests reproduce both original bugs, then pass with the fixes: a 160-message mailbox fills in two batches without duplicates; dated mail retains its timestamp and undated mail uses the fallback.
- `Scripts/release.sh`: runs `swift run EverydayChecks` and checks its exit status plus final success marker. Removed the fixed `.build/out/Products/Debug` path and the pipeline that could ignore compiler failures and run a stale checks executable.
- Validation: all 98 Windows core tests pass on this Mac using `/Users/xavi/.cargo/bin/cargo test -p everyday-core --locked` from `windows/`. `zsh -n Scripts/release.sh` passes. A mocked compiler failure confirms the release script stops before mutating versions or packaging anything. No release was created and no Windows installer was built/tested on Windows.

### Overnight polish (6 November, before 00:20 handover)
- `MailService.backend(for:)` now throws `MailAccountError.unavailable` when the owning account is disconnected instead of falling back to another account. Archive/trash/mark-read batches resolve every owner before any remote command. Existing UI error handling displays the reconnect message; no Mac view files changed.
- `Database.transaction` serializes synchronous work on the database queue and supports nested savepoints. Mail sync now commits mail, removals, search entries, per-account cursor, and per-account timestamp together; failed writes roll the entire account batch back. Other accounts still sync. A partial failure no longer updates the global successful-sync timestamp.
- Added fake-server/in-memory failure-injection checks: a later insert aborts an account batch; earlier inserts and FTS entries roll back; its cursor stays unchanged; another account still commits; missing-account actions send no remote commands. Added nested rollback checks.
- Midnight exposed an existing Quick Add bug: NSDataDetector ignored the supplied `now`. Common relative days (today, tomorrow, tonight, weekdays) now use the supplied date/calendar while retaining detected times. Removed the incorrect “add seven days” adjustment for explicit historical dates. Added leap-day and past-weekday-time checks.
- Validation so far: full Mac checks passed after these changes (live AI/account/send checks disabled). Further work and final verification will be recorded at handover.

### Windows briefing parity (6 November)
- Ported all seven highlight kinds to the Rust text helpers and Windows renderer. Dotted/empty/incomplete model tags are cleaned, and untrusted text remains HTML-escaped.
- Briefing generation now requests `## Needs you`, `## Today`, and `## News`, omitting empty sections. Windows renders these as small section headings and paragraphs. Handled-sender scrubbing preserves headings and drops empty sections; speech/notification text strips headings and highlight tags.
- Added `windows/app/ui/format.js` shared by production and the browser harness. Removed the stale copied `test/main.js`; the harness loads the production scripts directly. Updated the stub with sectioned samples.
- Verification: 101 Rust core tests and 5 Node formatting tests pass. Browser harness confirms all three headings and live handling of the sample Google notice without losing sections. Tauri shell compile check and final checks are pending handover.

### Recommended follow-ups for Claude (review findings, not fixed)
- Account isolation: IMAP message IDs are account-tagged, but thread IDs are still derived solely from the message's thread key; `MailService.rows()` groups by that thread ID. The same conversation in two accounts can merge and a thread action can affect both. Namespace thread identity by account with an explicit migration for handled threads, snoozes, and drafts.
- Once correctness is covered, port the briefing sections, highlight kinds, readable mail bodies, security-only front-facing “That was me”, and multi-account behavior to Windows. See the existing next-work list below.

## Claude
- Note from Codex: Please create and maintain your own dated subsection here for every continuation. Record your changes, commits, tests, remaining issues, and decisions so Codex can pick up your work; keep the Codex section intact.

### 6 November: finishing Codex's last round (Claude)
- Codex hit its usage limit mid-handover with work uncommitted. Reviewed and committed it unchanged:
  - Mac: `Database.pruneMail(before:)` removes expired mail from search (`mail_fts`) and triage as well as the inbox, in one transaction; `store`/`removeLocal` wrap their writes in a savepoint (safe to nest).
  - Windows SMTP: malformed or non-ASCII server replies return an error instead of panicking; reply headers strip control characters (no header injection); envelope addresses with control characters or `<>` are rejected before any command is sent. Three new tests.
  - Windows replies: per-conversation draft kept across navigation, restored after a failed send, no duplicate sends while one is pending, undo keeps newer typing (`windows/app/ui/replies.js`, `test/replies.test.cjs`). "That was me" in a menu for ordinary mail, prominent for security notices. Media CSP allows generated voice audio.
- Verified: Mac `EverydayChecks` ALL CHECKS PASSED (live checks off), 104 Rust core tests, `cargo check -p everyday-app`, 10 Node UI tests, `git diff --check` clean.
- Still open from Codex's review: thread IDs are not namespaced by account (see the follow-ups above). Gallery placement of the widgets on the user's desktop still to be confirmed by the user.

### Previous Opus session (all in `49d1f15` unless noted)
- "That was me": shown up front only for account-security mail (`MailBundler.isSecurityNotice`), otherwise in the "…" and right-click menus; items leave attention lists instantly.
- Briefing written in sections (`## Needs you`, `## Today`, `## News`), rendered as small headings; `Briefing.sections/plain`; heading-safe removal of handled senders. Shorter / Full length button. Editable briefing prompt in Settings → Advanced.
- Email bodies formatted (`MailText`): link words become links, tracking URLs hidden.
- News: Anthropic News/Research (community RSS mirrors, Anthropic has no feed), OpenAI, Hugging Face, The Decoder; 11 new categories; follow your own topics (Settings → Interests); removed default sources stay removed.
- Light mode: warm kraft palette plus paper grain (`PaperGrain`, `.paper()` in Theme.swift).
- Several mail accounts (IMAP list plus Gmail API); per-account ids, sync state and routing.
- Highlight kinds: urgent, action, date, person, money, number, place.
- Legal pages on the site (privacy, terms, licences), mobile overflow fixes, Open-Meteo attribution in the app.
- Android groundwork: desktop-only Rust deps gated by target; plan in ANDROID.md.

## Not done / next
- Widget launch and timeline rendering are fixed (above). Confirm normal gallery placement on the user's desktop; the eight-widget catalogue and live Weather timeline have been verified in Apple's WidgetKit Simulator.
- Port this session's Mac features to the Windows app (multi-account, new highlight kinds, briefing sections, shorter button, editable prompt, email formatting, security-only "That was me", new feeds and topics).
- Mac signed download (needs Developer ID; the release script is implemented, but actual Developer ID signing/notarization remains unverified).
- Get the legal pages reviewed (the local privacy page no longer labels itself a draft).
