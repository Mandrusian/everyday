# Memories (keep across compaction)

## Pending decisions from the user
- **Widgets redesign plan awaiting approval.** Proposed: (1) flat design, a solid paper or charcoal colour, no texture or gradient; (2) a per-widget Style option, Flat or Liquid Glass, through AppIntent configuration; (3) a new month-grid calendar widget like macOS Calendar, with the month in clay, today in a clay circle, dimmed weekends and event dots; (4) fixes: Needs you skips automated bundles, Your day uses a real 1–2 sentence brief, better Clock sizes; (5) optional extra widgets: Countdown, Saved story, Focus, large "Today". The user hasn't said yes or picked from (5).
- **Windows UI must be fully native, not a WebView.** The user said "we need a fully windows ui, preferably rust but whatever works best". Current Windows app = Tauri 2 with an HTML/JS UI in `windows/app/ui` over the Rust core `windows/core`. Next step: recommend a stack and get approval before rewriting. Candidates: Rust with `windows-rs` + WinUI 3 (awkward from Rust), Slint (Rust, native-looking, has a Fluent style), egui/iced (not native-looking), or C# WinUI 3 calling the Rust core over FFI (most native Fluent look, best tooling). Keep the Rust core either way.

## User preferences
- Name is "everyday." (the period is part of it). Design: Claude-style warm paper, ink and clay, minimal, flat (no gradients), serif headlines. Light mode = warm kraft paper.
- Wants polish above all; hates generic AI look; wants concise copy.
- "That was me" only up front for account-security mail; everywhere else in the "…" or right-click menu, and it must vanish instantly.
- Briefing has small section headings; highlights in seven kinds.
- Free and open source (GPL-3.0). No payments anywhere.
- Uses the yabai window manager; says "keep going, don't make me approve" for long runs, but wants plans approved for big new features.
- Ultracave (terse) reply mode is on.

## Facts
- Repo: github.com/Mandrusian/everyday (public). Site: everyday.mandrusia.tech (GitHub Pages from `site/`, Cloudflare DNS). Release v0.1.0 has the Windows installers.
- Handoff log lives in NOTES.md (Codex section plus dated Claude sections). Add a dated Claude section after each round.
- Mac: SwiftPM, no Xcode; `./Scripts/bundle.sh`, `./Scripts/install.sh`, `swift run EverydayChecks`. Widgets: the `EverydayWidgets` target and appex. Codex fixed the launch crash (it needed Apple's extension entry point, commit `ab94697`); widgets confirmed working on the desktop.
- zsh has a `log` builtin: use `/usr/bin/log` for macOS logs.
- `.env` (git-ignored) holds `CF_API_TOKEN`; never handle tokens myself.
- Demo contact name: Oscar Fox (never Dana).
