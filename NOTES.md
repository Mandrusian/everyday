# Handoff notes (5 November 2026)

State of everyday. for whoever picks this up next. Read README.md, ROADMAP.md, WINDOWS.md and ANDROID.md for the bigger picture.

## Repo and build
- Repo: github.com/Mandrusian/everyday (public, GPL-3.0). Branch `main`, last pushed commit `49d1f15`. Work after that (below) is **not committed yet**.
- Mac app: SwiftPM only, no Xcode. `./Scripts/bundle.sh` builds `build/everyday.app`; `./Scripts/install.sh` copies it to `~/Applications/everyday.app`. Checks: `swift run EverydayChecks` (must end `ALL CHECKS PASSED`; the live Gemini "speech: replay comes from the on-disk cache" check is occasionally flaky, so rerun before chasing it).
- Dev copy with its own data: `./Scripts/dev.sh` (`EVERYDAY_DEV=1`). Screenshots of every screen: `EVERYDAY_DEV=1 EVERYDAY_SNAPSHOT_DIR=/some/dir build/everyday.app/Contents/MacOS/Everyday`.
- Windows: Rust workspace in `windows/` (`cargo test -p everyday-core`, 96 tests). CI in `.github/workflows/windows.yml`; pushing a `v*` tag builds installers and attaches them to a GitHub release. Release `v0.1.0` exists with the `.exe`, `.msi` and SHA256SUMS.
- Website: static `site/`, deployed to GitHub Pages by `.github/workflows/pages.yml`, custom domain everyday.mandrusia.tech (Cloudflare DNS CNAME, done). HTTPS certificate from GitHub was still pending; when issued, tick Enforce HTTPS in repo Settings → Pages.
- Secrets for scripts live in `.env` (git-ignored); template in `.env.example`. `Scripts/cloudflare-dns.sh` manages DNS with `CF_API_TOKEN`.

## Uncommitted changes in the working tree
- `Resources/Info.plist` and `Resources/Widgets-Info.plist`: added `CFBundleSupportedPlatforms`, `DTPlatformName`, `DTSDKName`, `DTPlatformVersion` while debugging widgets (harmless, keep or drop).
- Verify with `git status` before committing.

## Open problem: macOS widgets don't appear in the widget gallery
What exists: `Sources/EverydayWidgets/Widgets.swift` (8 widgets: Clock, Weather, Up next, Brief, Quote of the day, Needs you, Top news, Tasks), executable target `EverydayWidgets` in `Package.swift` with `-application-extension`, bundled by `Scripts/bundle.sh` into `everyday.app/Contents/PlugIns/EverydayWidgets.appex` with `Resources/Widgets-Info.plist` and `Resources/widgets.entitlements` (app sandbox plus a read-only home-relative exception for `Library/Application Support/everyday/widgets/`). The app writes `~/Library/Application Support/everyday/widgets/snapshot.json` (`WidgetSnapshot` in EverydayCore, `AppModel.updateWidgets()`), and that file is being written correctly.

Diagnosis so far:
- `pluginkit -m -i app.everyday.mac.widgets` shows it registered and enabled (`+`).
- chronod finds the extension and launches it, but the process **crashes at launch** (`~/Library/Logs/DiagnosticReports/EverydayWidgets-*.ips`): `EXC_BREAKPOINT` / SIGTRAP inside `ExtensionFoundation _EXRunningExtension._shared` → `_EXExtension.bootstrap(with:)` → WidgetKit → `EverydayWidgets.$main()`. No error message in the report. chronod then logs `query failed ... NSCocoaErrorDomain Code=4099 connection invalidated`.
- A working third-party widget (`/Applications/ClickClack.app/Contents/PlugIns/ClickClackWidgetExtension.appex`) has the same Info.plist shape and `LC_MAIN`; the difference is it's signed with a team ID and has `com.apple.application-identifier` / `com.apple.developer.team-identifier` / app group entitlements. Ours is ad-hoc (`TeamIdentifier=not set`).
- Leading hypothesis: ExtensionFoundation's bootstrap needs an application identifier from the code signature, which ad-hoc signing doesn't provide. Things to try, one at a time, re-signing the installed appex then the app (not `--deep`), `killall chronod`, and checking for a new crash report:
  1. add `com.apple.security.get-task-allow` to `Resources/widgets.entitlements`;
  2. rename the widget bundle struct so it doesn't share the module name `EverydayWidgets`;
  3. sign with a free Apple ID "Personal Team" development certificate (needs Xcode once to create it) or a Developer ID, adding `com.apple.application-identifier`.
- Tried 1 and 2 (5 Nov, 23:34): `get-task-allow` added to `Resources/widgets.entitlements` and the bundle struct renamed to `EverydayWidgetBundle`. The extension still crashes at the same place (new report `EverydayWidgets-2026-11-05-233420.ips`). Both changes are kept but uncommitted. Option 3 (real signing) is the remaining lead.
- Useful commands: `/usr/bin/log stream --info --debug --style compact > file` (use the full path: zsh has its own `log` builtin, which silently returns nothing), then `killall chronod` and `grep -i everyday file`.

## Done this session (all in `49d1f15` unless noted)
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
- Fix widgets (above).
- Port this session's Mac features to the Windows app (multi-account, new highlight kinds, briefing sections, shorter button, editable prompt, email formatting, security-only "That was me", new feeds and topics).
- Mac signed download (needs Developer ID; `Scripts/release.sh` is ready).
- Privacy page still says it's a draft; get the legal pages reviewed.
