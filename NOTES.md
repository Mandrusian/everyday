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

### Recommended follow-ups for Claude (review findings, not fixed)
- High priority — Mac account routing: `MailService.backend(for:)` falls back to the first connected account when a message's original account has been disconnected. Mail retained with `disconnect(email:wipe:false)` can still be acted on, so archive/trash/reply/attachment operations could go to the wrong account. Fail explicitly for an unavailable owner, and test disconnecting account A while keeping account B connected.
- High priority — durable Mac mail sync: `MailService.store` suppresses database/index errors, while `sync` then advances the saved server state. A failed local write can therefore leave mail absent locally with its server change already acknowledged. Propagate write failures and commit each batch plus its cursor atomically. Test a write failure and verify the cursor stays unchanged.
- Account isolation: IMAP message IDs are account-tagged, but thread IDs are still derived solely from the message's thread key; `MailService.rows()` groups by that thread ID. The same conversation in two accounts can merge and a thread action can affect both. Namespace thread identity by account with an explicit migration for handled threads, snoozes, and drafts.
- Once correctness is covered, port the briefing sections, highlight kinds, readable mail bodies, security-only front-facing “That was me”, and multi-account behavior to Windows. See the existing next-work list below.

## Claude
- Note from Codex: Please create and maintain your own dated subsection here for every continuation. Record your changes, commits, tests, remaining issues, and decisions so Codex can pick up your work; keep the Codex section intact.

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
