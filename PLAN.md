# everyday. — Project Plan

Native macOS personal intelligence app: mail triage + personalized news + tasks + daily briefing + assistant. Local-first, BYO AI key, zero telemetry.

Status: PLAN ONLY. No code until approved.

---

## 1. Decisions to make (recommendation first)

| # | Decision | Recommendation | Why |
|---|----------|----------------|-----|
| 1 | Min OS | macOS 26 (Tahoe) only | Liquid Glass (`glassEffect`, `GlassEffectContainer`) is 26+. Foundation Models also 26+. Fallback to materials would double design work. |
| 2 | Distribution | Direct (notarized, Developer ID) + Sparkle updates. App Store later, optional. | Faster iteration, no review friction, sandbox still enabled either way. |
| 3 | Gmail access | Gmail API, OAuth PKCE, **tokens in Keychain, all processing on-device, no backend** | Avoids server-side data → likely avoids CASA (see risk R1). Must verify with Google before launch. |
| 4 | Other providers | Generic **IMAP/SMTP** (app passwords / OAuth for Outlook & iCloud) in Phase 4 | Gmail first; protocol abstraction from day one. |
| 5 | AI | Provider-agnostic `AIProvider` protocol: Anthropic, OpenAI, Google, OpenAI-compatible (Ollama/LM Studio), Apple Foundation Models | BYO key. On-device Apple model for cheap tasks (classification, tags); cloud model for summaries/chat. |
| 6 | Storage | SwiftData (SQLite) local; optional iCloud sync (CloudKit private DB) later | Local-first. CloudKit on macOS needs explicit capability setup. |
| 7 | Business model | Free/open-source or one-time purchase. No subscription, no backend. | Matches "no unnecessary subscriptions". |

---

## 2. Feature spec

### 2.1 Mail
- Accounts: Gmail (P1), IMAP/SMTP (P4), Outlook via MS Graph (P4 stretch).
- Local mailbox cache: headers + bodies for last N days (default 30), full-text search via SQLite FTS5.
- AI triage categories (stored as local labels, not pushed to Gmail unless user opts in): `Important`, `Needs reply`, `Deadline`, `Action item`, `Newsletter`, `Promo`, `Spam-suspect`, `FYI`.
- Thread summary (1–3 lines + key asks + dates).
- Reply suggestions: 3 tones, edit inline, **draft only**.
- Newsletter handling: collapse into a "Digest" lane; route to news reader.
- **Safety invariants (enforced in code, not prompts):**
  - AI layer has no `send`/`delete`/`archive` capability. It returns `ProposedAction` values.
  - Only `ActionExecutor`, invoked from a user-initiated UI confirmation, calls mail write APIs.
  - Send/delete require explicit per-item confirm. Bulk ops show a diff list.
  - Delete = move to Trash only; never permanent delete. Undo window for archive.
- Gmail scopes: start with `gmail.modify` (read, label, trash, draft) + `gmail.send`. Restricted scope → see R1.

### 2.2 News
- Sources: curated RSS/Atom registry (AP, Reuters*, BBC, NPR, Guardian, Ars, The Verge, Nature, etc.), user-addable feeds, plus topic feeds. *Check each feed's terms.
- Pipeline: fetch (conditional GET/ETag) → extract (readability on-device) → dedupe (title shingles + embedding cosine via `NLContextualEmbedding`/`NLEmbedding`) → cluster into "stories" → freshness filter (drop > configurable age, collapse updates) → rank → AI summary on demand ("Why it matters", source list, other outlets covering).
- Source trust: bundled reliability tiers (editable), shown as badge. Every summary cites source URLs; link out to original.
- Reader: elegant typography, summarise button in header, ask-about-article chat, text-to-speech (`AVSpeechSynthesizer`), save/archive.
- Legal: show headline + AI summary + link; full-text rendering only for feeds that provide it or via on-device extraction for user viewing (personal use). No redistribution, no server.

### 2.3 Swipe curation (onboarding + Settings → Retrain)
1. Pick categories (politics, tech, AI, science, gaming, business, world, aviation, entertainment, + custom keywords).
2. Card stack of ~20–30 real recent articles per chosen category. Right = interested (+1), left = not (−1), up = very (+3). Keyboard: →, ←, ↑; trackpad drag.
3. Model: lightweight on-device — per-topic/entity/source weights + embedding centroid ("interest vector") with time decay. No cloud training.
4. Ongoing signals: opens, read time, saves, "less like this", thumbs. Exploration quota (~10%) to avoid filter bubble; "Outside your bubble" slot.
5. Retrain: reset weights or re-run swipe deck; export/import profile JSON.

### 2.4 Daily Briefing
- Generated on schedule (user time) + on demand. Sections: Needs attention (mail), Top news (5–8 clusters), Today's calendar, Tasks due, Weather, Reminders.
- Inputs: EventKit (calendar + reminders), WeatherKit, local mail/news/tasks DB.
- Output cached; regenerates on change. Optional macOS notification + menu bar extra.

### 2.5 Smart Tasks
- Native task store (SwiftData). Fields: title, due, priority, source (email/manual/AI), linked thread, status.
- AI suggests tasks from emails/deadlines → shown as **suggestions** to accept/dismiss (never auto-created silently).
- Optional two-way sync with Apple Reminders via EventKit.
- Reminders via `UserNotifications`. Completion streaks (light).

### 2.6 Assistant
- Sidebar/⌘K panel; context-aware (current article/thread/task auto-attached).
- Tool-calling over local data: `searchMail`, `getThread`, `searchNews`, `listTasks`, `createTaskProposal`, `draftReply`. All write tools return proposals.
- Shows what context is being sent before send (transparency pane).

### 2.7 Dashboard
- Customizable widget grid: Briefing, Inbox priority, Top news, Tasks, Calendar, Weather, Saved. Drag/resize, per-widget settings, saved layouts.

### 2.8 Settings
General · Accounts · AI Providers (key entry → Keychain, model picker, per-feature model routing, monthly budget cap, token/cost log) · News (sources, freshness, trust) · Interests (retrain) · Mail rules · Privacy (data inspector, "what was sent to AI" log, wipe all) · Notifications · Appearance.

---

## 3. UX / design

- Window: `NavigationSplitView` — sidebar (Today, Inbox, News, Tasks, Saved, Assistant) → list → detail. Toolbar with Liquid Glass; search field in toolbar.
- Liquid Glass used for chrome/controls/floating elements (toolbar, swipe action bar, assistant composer, widget overlays), **not** for content backgrounds. Group with `GlassEffectContainer`; avoid nested glass.
- Typography: SF Pro for UI; New York (serif) for article body. Dynamic Type-style scaling, reader prefs.
- Motion: spring transitions, `matchedGeometryEffect`/`glassEffectID` morphs, swipe card physics via `DragGesture` + spring. Respect Reduce Motion / Reduce Transparency.
- A11y: full VoiceOver, keyboard-first (j/k, e, r, ⌘K), contrast checks over glass, Increase Contrast.
- Onboarding flow: Welcome → Privacy promise → Connect mail (skippable) → AI provider (skippable; on-device fallback) → Categories → Swipe deck → Dashboard setup → Done.
- Menu bar extra + Dock badge (urgent count) + Spotlight (App Intents) later.

---

## 4. Architecture

```
everyday.app (SwiftUI, Swift 6, strict concurrency)
├─ App/                 entry, scenes, commands, menu bar extra
├─ DesignSystem/        tokens, glass components, typography, motion
├─ Features/
│   ├─ Onboarding  Dashboard  Briefing  Mail  News  Tasks  Assistant  Settings
├─ Domain/              pure models + use-cases (no UI/IO)
│   ├─ Triage  Ranking  Interest  Dedupe  ProposedAction
├─ Services/ (protocol-first, actor-isolated)
│   ├─ Mail:      MailProvider (Gmail, IMAP) + SyncEngine
│   ├─ News:      FeedFetcher, Extractor, Clusterer
│   ├─ AI:        AIProvider (Anthropic/OpenAI/Google/Compat/Apple), PromptLibrary, UsageMeter, ContextRedactor
│   ├─ Calendar:  EventKit   Weather: WeatherKit   Notify: UserNotifications
│   ├─ Keychain:  SecItem wrapper (kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
├─ Persistence/         SwiftData models, FTS5 index, migrations
└─ Tests/               unit, snapshot, integration (fake providers)
```

- Modules as local Swift packages (`EverydayCore`, `EverydayAI`, `EverydayMail`, `EverydayNews`, `EverydayUI`) for build speed and boundaries.
- Concurrency: actors for sync/AI; `AsyncStream` for progress; `BGTask`-equivalent via `NSBackgroundActivityScheduler` for periodic fetch while app runs; login-item helper (SMAppService) optional for background briefing.
- AI orchestration: structured outputs (JSON schema) for classification; streaming for chat/summary; response cache keyed by content hash + prompt version; batch classification of new mail via cheap model; on-device Foundation Models for first-pass triage when available.
- Privacy by construction: `ContextRedactor` strips signatures/quoted history/tracking pixels/links params before AI; per-feature toggle for "send email bodies to cloud".
- Sandbox: App Sandbox on; entitlements: network client, Keychain, calendars, reminders, user notifications, WeatherKit (needs paid Apple Developer account).
- Secrets: API keys + OAuth refresh tokens in Keychain only; never logged; never in SwiftData/UserDefaults.

## 5. Data sources

| Domain | Source | Notes |
|---|---|---|
| Mail | Gmail API; IMAP (Network.framework or SwiftNIO-IMAP) | OAuth PKCE loopback/custom scheme via `ASWebAuthenticationSession` |
| News | Curated RSS/Atom; publisher-provided full text where offered; Guardian Open Platform (key, non-commercial) | GDELT only for discovery/metadata (keyless, 1 req/5 s, no full text). NewsAPI.org free tier unsuitable (dev only, 24 h delay). |
| Calendar/Reminders | EventKit | Full-access permission; macOS prompt quirks reported |
| Weather | Open-Meteo (no paid account); WeatherKit later if account acquired | WeatherKit needs entitlement + paid account |
| Embeddings | `NaturalLanguage` on-device | Free, private |

## 6. Privacy model

- No telemetry, no analytics, no crash reporting that phones home (opt-in local crash logs only).
- No everyday. servers. Network egress = mail provider, news publishers, weather, user's chosen AI provider. All listed in Settings → Privacy.
- AI transparency: per-request log (provider, model, feature, token count, exact payload viewable). Redaction preview. "Local only" mode (Apple model/Ollama).
- Data inspector + one-click wipe per account/everything. Local DB encrypted at rest via FileVault + Data Protection class; optional app lock (Touch ID via `LocalAuthentication`).
- Prompt-injection defence: emails/articles are untrusted. Delimited as data, AI has no write capability, all actions are proposals needing click.

## 7. Risks & technical limits

| ID | Risk | Mitigation |
|----|------|------------|
| R1 | Gmail restricted scopes require Google OAuth verification; CASA security assessment likely when data goes through third-party servers. Sources conflict on whether purely local apps are exempt; cost reports range ~$540 to several $k/yr. Unverified apps limited to 100 test users with warning screen. | Local-only architecture, no backend. **Confirm with Google before building Phase 1 launch.** Personal use (you) works immediately in "testing" mode. Fallback: IMAP + app password. |
| R2 | News licensing: free APIs mostly non-commercial/dev-only; paywalled publishers. | RSS + link-out + short AI summaries; avoid redistribution; no server. |
| R3 | Apple on-device model: ~3B params, weak world knowledge/complex reasoning, needs Apple Intelligence-enabled Mac. | Use only for classification/short summaries; runtime availability check; cloud fallback. |
| R4 | Cost: AI per-mail classification can be expensive. | Cheap-model routing, content-hash cache, batching, budget cap, on-device first pass. |
| R5 | Hallucinated summaries. | Citations, quote-grounded prompts, show source text on tap. |
| R6 | Liquid Glass legibility/perf. | Glass only on chrome; test Reduce Transparency; single container per cluster. |
| R7 | CloudKit sync on macOS needs manual capability config; SwiftData migrations. | Sync deferred to Phase 5; versioned schema from day one. |
| R8 | EventKit Reminders permission flakiness on macOS. | Own task store primary; Reminders sync optional. |
| R9 | WeatherKit needs paid dev account. | Fallback Open-Meteo (keyless). |
| R10 | Gmail API quota/latency; History API for incremental sync. | Use `history.list` incremental sync, batch requests. |

## 8. Competitive landscape (what to learn / avoid)

- **Superhuman** (~$30/mo): speed, keyboard, split inbox → copy keyboard-first speed; avoid price.
- **Shortwave**: best AI summaries/search, Gmail-only, cloud-based → we match with local-first + BYO key.
- **Spark**: cross-platform, team features, lighter AI.
- **Apple Mail/News/Intelligence**: native feel baseline; no cross-domain briefing.
- Gap: nobody unifies mail + news + tasks + briefing with local-first privacy and BYO model. That is the positioning.

## 9. Phases

| Phase | Scope | Exit criteria |
|---|---|---|
| 0 Foundations (1–2 wk) | Xcode project, SPM modules, design system, Keychain, AIProvider + 2 providers, settings shell, CI | Glass shell runs; AI key stored; test call works |
| 1 Mail MVP (3–4 wk) | Gmail OAuth, sync, inbox UI, thread view, triage labels, summaries, draft replies, ProposedAction/confirm flow, FTS search | Daily-drivable read-only + draft; no unapproved writes verified by tests |
| 2 News (3–4 wk) | Feed registry, extractor, dedupe/cluster, reader, summarize button, Saved | Clean, deduped feed; summaries with citations |
| 3 Curation + onboarding (2–3 wk) | Category pick, swipe deck, interest model, feed ranking, retrain, full onboarding | Measurable ranking lift (self-rated) after 25 swipes |
| 4 Tasks, briefing, assistant (3–4 wk) | Task store + suggestions, EventKit, WeatherKit, briefing generator, assistant with tools | End-to-end morning briefing |
| 5 Dashboard & polish (2–3 wk) | Widgets, menu bar, notifications, a11y audit, perf, animations | Instruments clean, VoiceOver pass |
| 6 Expand (ongoing) | IMAP/Outlook, iCloud sync, App Intents/Shortcuts, widgets, notarized release + Sparkle | Public release |

## 10. Implementation strategy

- Vertical slices; ship each phase usable. Protocols + fakes first so UI/AI develop without live accounts.
- Testing: unit on Domain (triage parsing, dedupe, interest model); golden-file prompts with recorded fixtures; UI snapshot for glass components; safety test: assert AI layer cannot reach write APIs (compile-time via module boundaries + runtime test).
- Prompt versioning + eval set (~100 labelled emails/articles, locally stored) to compare models.
- Tooling: Xcode 26, Swift 6, SwiftLint, SwiftFormat, GitHub Actions (macOS runner), notarization script.
- Key deps (minimal): Sparkle, SwiftSoup (HTML parse), swift-nio-imap (P6), FeedKit or own parser. Everything else Apple frameworks.

## 11. Resolved decisions (user answers)

1. **Gmail only first**, connectable by the user (own Google Cloud OAuth client). IMAP deferred.
2. **Personal now; maybe paid later + a reduced-feature OSS edition.** Open-core split: `EverydayCore` (mail, news, tasks, AI providers) = OSS; briefing/assistant tools/dashboard polish = possible paid layer. Keep module boundary clean from day one. Public paid release triggers R1 (CASA) — decide later.
3. **Default AI: Gemini** (Google AI Studio key; free tier exists). Keep `AIProvider` abstraction so others stay swappable. Routing: Flash-class model for triage/classification, Pro-class for summaries/chat.
4. **Mail labels: local-only by default** (labels live in everyday.'s DB; nothing changes in Gmail). Optional later toggle to mirror as Gmail labels.
5. **News sources (curated default pack, all editable, trust-tiered):**
   - Australia: ABC News, SBS News, Guardian Australia, The Conversation AU, Crikey, The Saturday Paper, Michael West Media, The New Daily
   - World/left-leaning: Guardian (world/US/UK), Al Jazeera, Democracy Now, The Intercept, Jacobin, Mother Jones; wire: AP, Reuters
   - Tech/AI: Ars Technica, The Verge, Wired, 404 Media, MIT Technology Review, IEEE Spectrum, Hacker News (front page), Simon Willison, Import AI, Google DeepMind / Anthropic / OpenAI blogs, arXiv cs.AI (filtered)
   - Science: Nature News, Quanta, New Scientist, Science Daily
   - Aviation: Aviation Herald, Simple Flying, AeroTime, Executive Traveller (AU), Australian Aviation
   - Gaming/entertainment: Rock Paper Shotgun, Eurogamer, Polygon-successor feeds, The Guardian culture, A.V. Club
   - Anti-bubble: small opt-in "outside your bubble" pack (e.g. Reuters-only, BBC, a centre/right outlet) feeding the exploration slot. Default on, 10%.
6. **No paid Apple Developer account** → changes below.

### Impact of no paid account
- **No WeatherKit** → use Open-Meteo (keyless, free, non-commercial; revisit if paid). Bureau of Meteorology has no stable public API.
- **No Developer ID / notarization** → personal use: build and run locally with free "Personal Team" signing (re-sign periodically). OSS: users build from source or right-click-open. Paid release requires the $99 USD/yr account.
- **No CloudKit/iCloud sync** → Phase 6 sync dropped; optional export/import and folder-based sync (iCloud Drive file) instead.
- Keychain, EventKit, notifications, Foundation Models all work with free signing.
- Verify early (Phase 0 spike): sandbox + Keychain + `ASWebAuthenticationSession` under Personal Team signing.

### Gmail personal-use gotcha
OAuth client in "Testing" status: **refresh tokens expire after 7 days** (external user type). Options: (a) set app to "In production" unverified — token no longer expires, shows "unverified app" warning, capped at 100 users (fine for personal/small OSS); (b) re-auth weekly. Plan uses (a). Requires own Google Cloud project; OSS users bring their own client ID.

## Sources
- [GlassEffectContainer — Apple docs](https://developer.apple.com/documentation/swiftui/glasseffectcontainer.md)
- [Liquid Glass best practices](https://dev.to/diskcleankit/liquid-glass-in-swift-official-best-practices-for-ios-26-macos-tahoe-1coo)
- [Foundation Models limits](https://www.natashatherobot.com/p/apple-foundation-models)
- [Gmail API limits/CASA](https://www.usecarly.com/blog/gmail-api-limits/)
- [Gmail local app / CASA forum](https://security.googlecloudcommunity.com/google-security-operations-2/what-happened-to-local-app-gmail-api-access-7138)
- [Free news APIs](https://dev.to/hassann/top-10-free-news-apis-for-developers-5fg8)
- [macOS SwiftData+CloudKit](https://developer.apple.com/forums/thread/784215)
- [EventKit Reminders macOS](https://developer.apple.com/forums/thread/745752)
- [Superhuman alternatives](https://blog.superhuman.com/superhuman-alternatives/)
