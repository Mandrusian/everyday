import SwiftUI
import WidgetKit
import AppKit
import UserNotifications
import EverydayCore

enum AppSection: String, CaseIterable, Identifiable {
    case today, inbox, news, tasks, saved, settings
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .today: "sun.max"
        case .inbox: "tray"
        case .news: "newspaper"
        case .tasks: "checklist"
        case .saved: "bookmark"
        case .settings: "slider.horizontal.3"
        }
    }
}

struct Banner: Identifiable, Equatable {
    let id = UUID(); var text: String; var isError: Bool; var undo: (() -> Void)? = nil
    static func == (a: Banner, b: Banner) -> Bool { a.id == b.id }
}

@MainActor @Observable
final class AppModel {
    // Services
    let db: Database
    let prefs = Prefs.shared
    let ai: AIService
    let intel: Intelligence
    let auth: GoogleAuth
    let mail: MailService
    let interests: InterestModel
    let news: NewsService
    let tasks: TaskStore
    let sync: SyncHost
    var syncTick = 0
    /// Sidebar shrunk to icons, like the Windows app. Remembered between launches.
    var sidebarCollapsed = Prefs.shared.bool("sidebar.collapsed", default: false) { didSet { prefs.set(sidebarCollapsed, "sidebar.collapsed") } }
    let weather: WeatherService
    let calendar = CalendarService()
    let briefingService: BriefingService
    let context: ContextBuilder

    // Navigation
    var section: AppSection = .today
    var showAssistant = false
    var showOnboarding: Bool
    var settingsPane: SettingsPane = .general
    var inboxFilter: InboxFilter = .priority
    /// Skim reading: coloured highlights in summaries (on by default) and sans-serif for summary text (on by default).
    var skim: Bool = Prefs.shared.bool("skim.highlights", default: true) { didSet { Prefs.shared.set(skim, "skim.highlights") } }
    var skimSans: Bool = Prefs.shared.bool("skim.sans", default: true) { didSet { Prefs.shared.set(skimSans, "skim.sans") } }
    var appearance: String = Prefs.shared.string(Prefs.Key.appearance, default: "dark") { didSet { Prefs.shared.set(appearance, Prefs.Key.appearance) } }
    var dashboardHidden: Set<String> = Set(Prefs.shared.strings("dashboard.hidden"))

    // Data
    var rows: [MailRow] = []
    var stories: [Story] = []
    var savedArticles: [Article] = []
    var openTasks: [TaskItem] = []
    var doneTasks: [TaskItem] = []
    var suggestions: [TaskSuggestion] = []
    var weatherNow: WeatherNow?
    var briefing: Briefing?
    var briefingLive: String?            // text so far while the briefing is being written
    var usedReplies: Set<String> = []
    var selectedBundleID: String?
    var returnBundleID: String?          // set when a source was opened from a bundle
    var events: [CalendarEvent] = []
    var chat: [ChatMessage] = []
    var chatStreaming = false

    // Status
    var syncingMail = false
    var mailError: String? = nil          // last sync failure, shown in the sidebar with a retry
    var triaging = false
    var refreshingNews = false
    var generatingBriefing = false
    var shorteningBriefing = false
    var mailProgress = ""
    var banner: Banner?
    var selectedThread: String?
    var selectedStoryID: String?
    var userName: String { prefs.string("userName", default: NSFullUserName().components(separatedBy: " ").first ?? "there") }

    private var timers: [Task<Void, Never>] = []

    init() {
        let database = (try? Database(url: Database.defaultURL())) ?? (try! Database(url: nil))
        db = database
        ai = AIService(db: database)
        intel = Intelligence(ai: ai)
        auth = GoogleAuth()
        mail = MailService(db: database, auth: auth, intelligence: intel)
        interests = InterestModel(db: database)
        news = NewsService(db: database, interests: interests)
        tasks = TaskStore(db: database)
        sync = SyncHost(data: SyncData(db: database, tasks: tasks, mail: mail, prefs: .shared))
        weather = WeatherService(db: database)
        context = ContextBuilder(mail: mail, tasks: tasks, news: news, weather: weather, calendar: calendar)
        briefingService = BriefingService(db: database, intelligence: intel, context: context)
        showOnboarding = !Prefs.shared.bool(Prefs.Key.onboarded)
        reloadLocal()
        chat = (try? database.all("chat", limit: 200, as: ChatMessage.self))?.sorted { $0.date < $1.date } ?? []
        // Wi‑Fi sync with paired devices: reload what other devices changed.
        sync.onChange = { [weak self] in Task { @MainActor in self?.reloadLocal(); self?.reloadTasks(); self?.scheduleTaskNotifications() } }
        sync.onStatus = { [weak self] in Task { @MainActor in self?.syncTick += 1 } }
        sync.onSetup = { [weak self] msg in Task { @MainActor in
            guard let self else { return }
            self.showOnboarding = false; self.say(msg); self.reloadLocal()
            await self.syncMail()
        } }
        sync.start()
    }

    // MARK: Banner

    func say(_ text: String, error: Bool = false, undo: (() -> Void)? = nil, seconds: Double? = nil) {
        let b = Banner(text: text.count > 260 ? String(text.prefix(257)) + "…" : text, isError: error, undo: undo)
        banner = b
        let secs = seconds ?? (error ? 7 : (undo == nil ? 3.5 : 7))
        Task { try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000)); if banner == b { banner = nil } }
    }

    func fail(_ error: Error, _ context: String) { say("\(context): \(error.localizedDescription)", error: true) }

    // MARK: Local reload

    func reloadLocal() {
        rows = mail.rows()
        stories = news.stories(limit: 80)
        savedArticles = news.savedArticles()
        openTasks = tasks.open()
        doneTasks = tasks.completed()
        suggestions = mail.suggestions()
        weatherNow = weather.cached()
        briefing = briefingService.latest().map { briefingService.scrubbed($0) }
        events = calendar.upcoming()
        updateWidgets()
    }

    private var mailReloadGeneration = 0
    /// Rebuilds the inbox off the main thread so clicks never wait on the database.
    func reloadMail() {
        mailReloadGeneration += 1
        let gen = mailReloadGeneration
        Task.detached(priority: .userInitiated) { [weak self, mail] in
            let r = mail.rows(), s = mail.suggestions()
            await self?.apply(rows: r, suggestions: s, generation: gen)
        }
    }
    private func apply(rows r: [MailRow], suggestions s: [TaskSuggestion], generation gen: Int) {
        guard gen == mailReloadGeneration else { return }   // a newer reload is already on its way
        animated { rows = r; suggestions = s }
    }
    // MARK: Desktop widgets

    private var widgetWrite: Task<Void, Never>?
    /// Writes what the widgets show and asks macOS to redraw them. Debounced so a burst of changes writes once.
    func updateWidgets() {
        widgetWrite?.cancel()
        widgetWrite = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            var s = WidgetSnapshot()
            s.name = userName
            if let w = weatherNow {
                s.weather = .init(city: w.city, temp: w.temperature, condition: w.condition, high: w.high, low: w.low,
                                  hours: w.hourly.filter { $0.date > Date() }.enumerated().filter { $0.offset % 3 == 0 }.prefix(5).map { .init(date: $0.element.date, temp: $0.element.temp) })
            }
            s.events = events.prefix(8).map { .init(title: $0.title, start: $0.start, allDay: $0.isAllDay) }
            if let b = briefing { s.brief = WidgetSnapshot.shortBrief(b.text) }
            let att = rows.filter(MailService.isAttention)
            s.needsCount = att.count
            s.needsYou = att.prefix(3).map { .init(who: $0.message.fromName, what: $0.triage?.summary.isEmpty == false ? $0.triage!.summary : $0.message.subject) }
            s.stories = stories.prefix(6).map { .init(title: $0.lead.title, source: $0.lead.source) }
            s.tasks = openTasks.prefix(6).map { .init(title: $0.title, due: $0.due) }
            s.quote = (try? db.get("quote", id: Self.quoteKey(prefs)) as WidgetSnapshot.Quote?) ?? nil
            s.style = prefs.string(Prefs.Key.widgetStyle, default: "glass")
            let cal = Calendar.current, now = Date()
            s.eventDays = Array(Set(events.filter { cal.isDate($0.start, equalTo: now, toGranularity: .month) }.map { cal.component(.day, from: $0.start) })).sorted()
            s.countdowns = widgetCountdowns.filter { $0.date > now.addingTimeInterval(-86400) }.sorted { $0.date < $1.date }
            s.customs = widgetCustoms
            try? s.write()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    var widgetCountdowns: [WidgetSnapshot.Countdown] {
        get { (try? JSONDecoder().decode([WidgetSnapshot.Countdown].self, from: Data(prefs.string(Prefs.Key.countdowns, default: "[]").utf8))) ?? [] }
        set { if let d = try? JSONEncoder().encode(newValue) { prefs.set(String(decoding: d, as: UTF8.self), Prefs.Key.countdowns) }; updateWidgets() }
    }
    var widgetCustoms: [WidgetSnapshot.Custom] {
        get { (try? JSONDecoder().decode([WidgetSnapshot.Custom].self, from: Data(prefs.string(Prefs.Key.customWidgets, default: "[]").utf8))) ?? [] }
        set { if let d = try? JSONEncoder().encode(Array(newValue.prefix(3))) { prefs.set(String(decoding: d, as: UTF8.self), Prefs.Key.customWidgets) }; updateWidgets() }
    }

    static func quoteKey(_ prefs: Prefs) -> String { BriefingSchedule.dayKey(Date()) + "|" + prefs.string(Prefs.Key.quoteTopic, default: "Stoicism").lowercased() }

    /// One quote a day on the reader's topic. Kept until the day or the topic changes.
    func refreshQuote(force: Bool = false) async {
        guard ai.isConfigured else { return }
        let key = Self.quoteKey(prefs)
        if !force, (try? db.get("quote", id: key) as WidgetSnapshot.Quote?) != nil { return }
        let recent = ((try? db.all("quote", limit: 30, as: WidgetSnapshot.Quote.self)) ?? []).map(\.text)
        if let q = try? await intel.quote(topic: prefs.string(Prefs.Key.quoteTopic, default: "Stoicism"), avoiding: recent) {
            try? db.put("quote", id: key, sort: Date().timeIntervalSince1970, q)
            updateWidgets()
        }
    }

    func reloadTasks() { let o = tasks.open(), d = tasks.completed(), s = mail.suggestions(); animated { openTasks = o; doneTasks = d; suggestions = s }; updateWidgets(); sync.syncNow() }
    func reloadNews() { let st = news.stories(limit: 80), sv = news.savedArticles(); animated { stories = st; savedArticles = sv } }

    // MARK: Lifecycle

    func start() {
        guard timers.isEmpty else { return }
        Task { await refreshEverything(silent: true) }
        Task { await checkForUpdates() }
        timers.append(Task { [weak self] in
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 60 * 1_000_000_000); await MainActor.run { self?.checkSnoozes(); self?.checkMorningBriefing() } }
        })
        timers.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000)
                await self?.refreshEverything(silent: true)
            }
        })
    }

    func refreshEverything(silent: Bool = false) async {
        async let n: Void = refreshNews(silent: silent)
        async let m: Void = syncMail(silent: silent)
        async let w: Void = refreshWeather(silent: true)
        _ = await (n, m, w)
        events = calendar.upcoming()
        if prefs.bool("autoBriefing", default: true), ai.isConfigured, briefingService.isStale(hour: Int(prefs.double(Prefs.Key.briefingHour, default: 7))) {
            await generateBriefing(silent: true)
        }
        scheduleTaskNotifications()
        await refreshQuote()
        updateWidgets()
    }

    func refreshWeather(silent: Bool = false) async {
        do { weatherNow = try await weather.fetch() } catch { if !silent { fail(error, "Weather") } }
    }

    func refreshNews(silent: Bool = false, force: Bool = false) async {
        guard !refreshingNews else { return }
        refreshingNews = true; defer { refreshingNews = false }
        let r = await news.refresh(force: force)
        reloadNews()
        if !silent { say(r.failures > 0 ? "News updated. \(r.failures) sources did not respond." : "News updated.", error: false) }
    }

    func syncMail(silent: Bool = false) async {
        guard mail.isConnected, !syncingMail else { return }
        syncingMail = true; defer { syncingMail = false; mailProgress = "" }
        do {
            mailError = nil
            let n = try await mail.sync { [weak self] p in Task { @MainActor in self?.mailProgress = p } }
            reloadMail()
            if ai.isConfigured {
                triaging = true; defer { triaging = false }
                _ = try await mail.triagePending { [weak self] d, t in Task { @MainActor in self?.mailProgress = "Sorting mail \(d) of \(t)" } }
                reloadMail()
            }
            if !silent { say(n == 0 ? "Mail is up to date." : "Synced \(n) messages.") }
        } catch {
            if !(error is CancellationError) { mailError = error.localizedDescription }
            if !silent || !(error is CancellationError) { fail(error, "Mail") }
        }
    }

    /// Writes the briefing with the text appearing as the model produces it.
    func generateBriefing(silent: Bool = false) async {
        guard !generatingBriefing else { return }
        guard ai.isConfigured else { if !silent { say("Add an AI provider key in Settings to write briefings.", error: true) }; return }
        generatingBriefing = true; briefingLive = ""
        defer { generatingBriefing = false; briefingLive = nil }
        do {
            let b = try await briefingService.generate(name: userName) { [weak self] text in Task { @MainActor in self?.briefingLive = text } }
            usedReplies = []
            animated { briefing = b }
            updateWidgets()
            Task { await loadReplies() }
        } catch { if !silent { fail(error, "Briefing") } }
    }

    /// Swaps between a shorter version of the briefing and the full one.
    func toggleShortBriefing() async {
        guard let b = briefing, !shorteningBriefing else { return }
        if b.fullText != nil { animated { briefing = briefingService.restoreFull(b) }; return }
        guard ai.isConfigured else { say("Add an AI provider key in Settings to shorten the briefing.", error: true); return }
        shorteningBriefing = true; defer { shorteningBriefing = false }
        do { let x = try await briefingService.shorten(b); animated { briefing = x } } catch { fail(error, "Briefing") }
    }

    func loadReplies() async {
        guard let b = briefing else { return }
        let x = await briefingService.loadReplies(for: b)
        if x.generatedAt == briefing?.generatedAt { animated { briefing = x } }
    }

    // MARK: Handling mail (local) and quick replies

    private var briefingRefresh: Task<Void, Never>?
    /// After mail is marked handled the briefing is written again (after a short pause, so several clicks make one rewrite).
    func scheduleBriefingRewrite() {
        guard briefing != nil, ai.isConfigured, prefs.bool(Prefs.Key.briefingAutoRewrite, default: true) else { return }
        briefingRefresh?.cancel()
        if let b = briefing { let x = briefingService.scrubbed(b); if x.text != b.text { animated { briefing = x } } }   // instant: the sentence goes before the rewrite finishes
        briefingRefresh = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            var waited = 0
            while generatingBriefing && waited < 60 && !Task.isCancelled { try? await Task.sleep(nanoseconds: 500_000_000); waited += 1 }   // never skipped because another rewrite is running
            if !Task.isCancelled { await generateBriefing(silent: false) }
        }
    }

    func markHandled(_ threadIDs: [String], label: String = "Marked as handled.") {
        let ids = mail.expandedThreadIDs(Array(Set(threadIDs)))
        // Quiet them on screen at once, so they leave attention lists before the database catches up.
        let gone = Set(ids)
        animated {
            rows = rows.map { r in
                guard gone.contains(r.message.threadId), let t = r.triage else { return r }
                var x = r; x.triage = Triage(messageId: t.messageId, category: .fyi, priority: min(t.priority, 5), summary: t.summary, deadline: nil, actionItems: [], needsReply: false, promptVersion: t.promptVersion); return x
            }
            suggestions.removeAll { $0.threadId.map(gone.contains) ?? false }
        }
        for id in ids { mail.markHandled(threadId: id) }
        reloadMail(); reloadTasks(); scheduleBriefingRewrite()
        say(ids.count > 1 ? "Marked \(ids.count) conversations as handled." : label, undo: { [weak self] in guard let self else { return }; for id in ids { self.mail.unhandle(threadId: id) }; self.reloadMail(); self.scheduleBriefingRewrite() })
    }

    // MARK: Snooze, VIP and unsubscribe (all local; nothing is changed in the mail account)

    static func snoozeOptions(now: Date = Date()) -> [(title: String, date: Date)] {
        let cal = Calendar.current
        func at(_ hour: Int, _ d: Date) -> Date { cal.date(bySettingHour: hour, minute: 0, second: 0, of: d) ?? d }
        let evening = at(18, now) > now.addingTimeInterval(3600) ? at(18, now) : now.addingTimeInterval(3 * 3600)
        let tomorrow = at(8, cal.date(byAdding: .day, value: 1, to: now) ?? now)
        let weekend = cal.nextDate(after: now, matching: DateComponents(hour: 9, weekday: 7), matchingPolicy: .nextTime) ?? tomorrow
        let monday = cal.nextDate(after: now, matching: DateComponents(hour: 8, weekday: 2), matchingPolicy: .nextTime) ?? tomorrow
        return [("Later today", evening), ("Tomorrow morning", tomorrow), ("This weekend", weekend), ("Next week", monday)]
    }

    /// Puts a conversation away until `until`, adds a "Reply to …" task due then, and brings it back to the top at that time.
    func snooze(_ threadId: String, until: Date, label: String) {
        let last = mail.thread(threadId).last
        let task = TaskItem(title: "Reply to \(last?.fromName ?? "this conversation")", due: until, priority: .medium, source: .email, sourceDescription: last?.subject ?? "", threadId: threadId)
        mail.snooze(threadId: threadId, until: until, taskId: task.id)
        addTask(task)
        let next = nextThread(after: threadId)
        animated { rows.removeAll { $0.message.threadId == threadId } }
        if selectedThread == threadId { selectedThread = next }
        reloadMail()
        say("Snoozed until \(label.lowercased()).", undo: { [weak self] in guard let self else { return }; self.mail.clearSnooze(threadId: threadId); self.tasks.delete(task); self.reloadTasks(); self.reloadMail() })
    }

    /// Writes the briefing at the chosen hour and tells you with a notification. Runs once a day, also if the app opens later.
    func checkMorningBriefing() {
        guard prefs.bool(Prefs.Key.briefingNotify, default: false), ai.isConfigured, Bundle.main.bundleIdentifier != nil else { return }
        let hour = Int(prefs.double(Prefs.Key.briefingHour, default: 7))
        guard BriefingSchedule.shouldSend(now: Date(), hour: hour, lastSent: prefs.string(Prefs.Key.briefingLastNotified)) else { return }
        prefs.set(BriefingSchedule.dayKey(Date()), Prefs.Key.briefingLastNotified)
        Task { [weak self] in
            guard let self else { return }
            await self.refreshEverything(silent: true)
            await self.generateBriefing(silent: true)
            guard let b = self.briefing else { return }
            let c = UNMutableNotificationContent()
            c.title = "Good morning, \(self.userName)"; c.body = BriefingSchedule.preview(b.text); c.sound = .default
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "morning-briefing", content: c, trigger: nil))
        }
    }

    var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }
    var availableUpdate: UpdateChecker.Release?

    /// Looks for a newer version (at most once a day unless asked), and offers the download page. Nothing is installed automatically.
    func checkForUpdates(manual: Bool = false) async {
        if !manual {
            guard prefs.bool(Prefs.Key.autoUpdateCheck, default: true), Bundle.main.bundleIdentifier != nil else { return }
            if Date().timeIntervalSince1970 - prefs.double(Prefs.Key.lastUpdateCheck, default: 0) < 86_400 { return }
        }
        prefs.set(Date().timeIntervalSince1970, Prefs.Key.lastUpdateCheck)
        let feed = ProcessInfo.processInfo.environment["EVERYDAY_UPDATE_FEED"] ?? UpdateChecker.defaultFeed
        guard let r = await UpdateChecker.latest(feed: feed) else { if manual { say("Couldn't check for updates. Try again later.", error: true) }; return }
        if UpdateChecker.isNewer(r.version, than: appVersion) {
            availableUpdate = r
            say("everyday. \(r.version) is available.", undo: { NSWorkspace.shared.open(r.url) }, seconds: 12)
        } else if manual { say("You have the latest version (\(appVersion)).") }
    }

    func checkSnoozes() {
        let due = mail.dueSnoozes()
        guard !due.isEmpty else { return }
        reloadMail(); say(due.count == 1 ? "A snoozed conversation is back at the top of your inbox." : "\(due.count) snoozed conversations are back at the top of your inbox.")
    }

    /// Quick Look preview of an attachment. The file is downloaded only now, and apps or scripts are refused.
    func previewAttachment(_ m: EmailMessage, name: String) async {
        do {
            say("Opening \(name)…")
            let url = try await mail.attachmentFile(m, name: name)
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage"); p.arguments = ["-p", url.path]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run()
        } catch { fail(error, "Attachment") }
    }

    func saveAttachment(_ m: EmailMessage, name: String) async {
        do {
            let src = try await mail.attachmentFile(m, name: name)
            let dl = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            var dest = dl.appendingPathComponent(src.lastPathComponent), n = 1
            while FileManager.default.fileExists(atPath: dest.path) { dest = dl.appendingPathComponent("\(n) " + src.lastPathComponent); n += 1 }
            try FileManager.default.copyItem(at: src, to: dest)
            say("Saved to Downloads as \(dest.lastPathComponent).")
        } catch { fail(error, "Attachment") }
    }

    /// A reply is held for 10 seconds so it can be taken back. Undo puts the text back in the composer.
    var restoredDrafts: [String: String] = [:]
    static let sendDelay: Double = 10
    func queueSend(threadId: String, body: String) {
        var cancelled = false
        say("Sending your reply in \(Int(Self.sendDelay)) seconds.", undo: { [weak self] in cancelled = true; self?.restoredDrafts[threadId] = body; self?.say("Not sent. Your draft is back.") }, seconds: Self.sendDelay)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.sendDelay * 1_000_000_000))
            guard let self, !cancelled else { return }
            do { try await self.mail.sendReply(threadId: threadId, body: body, .fromUserAction()); self.say("Reply sent.") }
            catch { self.restoredDrafts[threadId] = body; self.fail(error, "Send") }
        }
    }

    // MARK: Inbox cleanup ("delete LinkedIn notifications older than a week")

    var showCleanup = false
    var cleanupPreset: CleanupPlan? = nil

    /// Runs an approved cleanup. Mail leaves the inbox at once; the server is only told after the undo window, so Undo needs no server call.
    func applyCleanup(_ threadIds: [String], action: MailQuery.Action, saveRule q: MailQuery?) {
        guard !threadIds.isEmpty else { return }
        if let q { mail.saveCleanupRule(q) }
        var removed: [EmailMessage] = []
        for id in threadIds { removed += mail.removeLocally(threadId: id) }
        animated { rows.removeAll { threadIds.contains($0.message.threadId) } }
        if let s = selectedThread, threadIds.contains(s) { selectedThread = nil }
        reloadMail()
        var cancelled = false
        let n = threadIds.count, what = n == 1 ? "1 conversation" : "\(n) conversations"
        say(action == .trash ? "Moving \(what) to Trash." : "Archiving \(what).", undo: { [weak self] in
            cancelled = true; self?.mail.restore(removed); self?.reloadMail(); self?.say("Put back. Nothing was changed.")
        }, seconds: Self.sendDelay)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.sendDelay * 1_000_000_000))
            guard let self, !cancelled else { return }
            do {
                if action == .trash { try await self.mail.commitTrash(removed, .fromUserAction()) } else { try await self.mail.commitArchive(removed, .fromUserAction()) }
            } catch {
                self.mail.restore(removed); self.reloadMail()
                self.fail(error, "Could not finish. The conversations are back in your inbox")
            }
        }
    }

    func toggleVIP(_ address: String) {
        let on = !mail.isVIP(address)
        mail.setVIP(address, on); reloadMail()
        say(on ? "\(address) is a VIP now. Their mail always rises to the top." : "\(address) is no longer a VIP.", undo: { [weak self] in self?.mail.setVIP(address, !on); self?.reloadMail() })
    }

    func ignoreSimilar(_ messages: [EmailMessage]) {
        var rules: [MailRule] = []
        for m in messages { rules.append(mail.ignoreSimilar(to: m)) }
        reloadMail(); reloadTasks(); scheduleBriefingRewrite()
        say("Mail like this won't be flagged again.", undo: { [weak self] in guard let self else { return }; for r in rules { self.mail.removeRule(r) }; for m in messages { self.mail.unhandle(threadId: m.threadId) }; self.reloadMail(); self.reloadTasks() })
    }

    private func messages(for ids: [String]) -> [EmailMessage] { let all = mail.emails(limit: 1000); return ids.compactMap { id in all.first { $0.id == id } } }

    func perform(_ r: QuickReply) {
        animated { usedReplies.insert(r.id) }
        let msgs = messages(for: r.messageIds)
        switch r.kind {
        case .handled: markHandled(msgs.map(\.threadId))
        case .ignore: ignoreSimilar(msgs)
        case .task:
            for m in msgs {
                let t = mail.triage(for: m.id)
                addTask(TaskItem(title: t?.actionItems.first ?? "Follow up: \(m.subject)", due: t?.deadline, priority: (t?.priority ?? 0) >= 75 ? .high : .medium, source: .email, sourceDescription: "\(m.fromName): \(m.subject)", threadId: m.threadId))
            }
            say(msgs.count == 1 ? "Task added." : "Added \(msgs.count) tasks.")
        case .remind:
            let cal = Calendar.current
            let evening = cal.date(bySettingHour: 18, minute: 0, second: 0, of: Date()) ?? Date()
            let due = evening > Date().addingTimeInterval(1800) ? evening : Date().addingTimeInterval(3 * 3600)
            for m in msgs { addTask(TaskItem(title: "Check: \(m.subject)", due: due, priority: .medium, source: .email, sourceDescription: m.fromName, threadId: m.threadId)) }
            say("I'll remind you at \(due.formatted(date: .omitted, time: .shortened)).")
        case .ask:
            showAssistant = true
            ask(r.text, extraContext: msgs.map { "Email from \($0.fromName), \"\($0.subject)\": \(ContextRedactor.clean($0.body, limit: 700))" }.joined(separator: "\n---\n"))
        }
    }

    // MARK: Instant mail actions: the screen changes first, the server is told in the background, and the change is put back if it fails.

    private func nextThread(after id: String) -> String? {
        guard let i = rows.firstIndex(where: { $0.message.threadId == id }) else { return nil }
        return rows.indices.contains(i + 1) ? rows[i + 1].message.threadId : (i > 0 ? rows[i - 1].message.threadId : nil)
    }

    private func removeThread(_ id: String, done: String, commit: @escaping ([EmailMessage]) async throws -> Void) {
        let next = nextThread(after: id)
        let msgs = mail.removeLocally(threadId: id)
        animated { rows.removeAll { $0.message.threadId == id } }     // instant: no database round trip before the screen updates
        if selectedThread == id { selectedThread = next }
        reloadMail(); say(done)
        Task {
            do { try await commit(msgs) } catch {
                mail.restore(msgs); reloadMail()
                fail(error, "Could not finish. The conversation is back in your inbox")
            }
        }
    }
    func archiveThread(_ id: String) { removeThread(id, done: "Archived.") { [mail] in try await mail.commitArchive($0, .fromUserAction()) } }
    func trashThread(_ id: String) { removeThread(id, done: "Moved to Trash.") { [mail] in try await mail.commitTrash($0, .fromUserAction()) } }
    /// Archives several conversations at once (one banner, one server call per conversation in the background).
    func archiveThreads(_ ids: [String]) {
        var removed: [EmailMessage] = []
        for id in ids { removed += mail.removeLocally(threadId: id) }
        animated { rows.removeAll { ids.contains($0.message.threadId) } }
        if let s = selectedThread, ids.contains(s) { selectedThread = nil }
        reloadMail(); say("Archived \(ids.count) conversations.")
        Task {
            do { try await mail.commitArchive(removed, .fromUserAction()) } catch {
                mail.restore(removed); reloadMail()
                fail(error, "Could not finish. The conversations are back in your inbox")
            }
        }
    }

    func markReadThread(_ id: String) {
        let msgs = mail.setReadLocally(threadId: id)
        guard !msgs.isEmpty else { return }
        reloadMail(); say("Marked as read.")
        Task { do { try await mail.commitMarkRead(msgs, .fromUserAction()) } catch { mail.restore(msgs); reloadMail(); fail(error, "Could not mark as read") } }
    }

    // MARK: Tasks

    func addTask(_ t: TaskItem) {
        var x = t
        if prefs.bool(Prefs.Key.remindersSync), calendar.reminderAccess == .granted { x.reminderIdentifier = calendar.addReminder(for: x) }
        tasks.save(x); reloadTasks(); scheduleTaskNotifications()
    }

    func update(_ t: TaskItem) { tasks.save(t); reloadTasks(); scheduleTaskNotifications() }

    func toggle(_ t: TaskItem) {
        let x = tasks.toggle(t)
        if let r = x.reminderIdentifier { calendar.setReminderCompleted(r, x.isDone) }
        reloadTasks(); scheduleTaskNotifications()
    }

    func delete(_ t: TaskItem) {
        if let r = t.reminderIdentifier { calendar.removeReminder(r) }
        tasks.delete(t); reloadTasks(); scheduleTaskNotifications()
    }

    func deleteCompletedTasks() {
        let gone = tasks.deleteCompleted()
        for t in gone { if let r = t.reminderIdentifier { calendar.removeReminder(r) } }
        reloadTasks(); say(gone.isEmpty ? "No completed tasks." : "Deleted \(gone.count) completed task\(gone.count == 1 ? "" : "s").")
    }
    func deleteAllTasks() {
        let gone = tasks.deleteAll()
        for t in gone { if let r = t.reminderIdentifier { calendar.removeReminder(r) } }
        reloadTasks(); scheduleTaskNotifications(); say("Deleted \(gone.count) task\(gone.count == 1 ? "" : "s").")
    }

    func accept(_ s: TaskSuggestion) {
        var t = tasks.accept(s)
        mail.dismiss(s)  // also hides suggestions with the same title from other emails
        if prefs.bool(Prefs.Key.remindersSync), calendar.reminderAccess == .granted, let id = calendar.addReminder(for: t) { t.reminderIdentifier = id; tasks.save(t) }
        reloadTasks(); scheduleTaskNotifications()
        say("Added “\(s.title)”.")
    }

    func dismiss(_ s: TaskSuggestion) { mail.dismiss(s); suggestions = mail.suggestions() }

    func scheduleTaskNotifications() {
        let center = UNUserNotificationCenter.current()
        guard prefs.bool(Prefs.Key.notifications, default: true), Bundle.main.bundleIdentifier != nil else { center.removeAllPendingNotificationRequests(); return }
        let upcoming = tasks.open().filter { ($0.due ?? .distantPast) > Date() }.prefix(40)
        center.removeAllPendingNotificationRequests()
        for t in upcoming {
            guard var due = t.due else { continue }
            let cal = Calendar.current
            let c = cal.dateComponents([.hour, .minute], from: due)
            if c.hour == 0 && c.minute == 0 { due = cal.date(bySettingHour: 9, minute: 0, second: 0, of: due) ?? due }
            guard due > Date() else { continue }
            let content = UNMutableNotificationContent()
            content.title = t.title
            content.body = t.priority == .high ? "High priority, due now" : "Due now"
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(dateMatching: cal.dateComponents([.year, .month, .day, .hour, .minute], from: due), repeats: false)
            center.add(UNNotificationRequest(identifier: t.id, content: content, trigger: trigger))
        }
    }

    func requestNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: News actions

    func react(_ a: Article, _ r: Reaction) { news.react(a, r); reloadNews() }
    func toggleSaved(_ a: Article) { news.toggleSaved(a); savedArticles = news.savedArticles() }

    // MARK: Assistant

    func ask(_ question: String, extraContext: String = "") {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !chatStreaming else { return }
        guard ai.isConfigured else { say("Add an AI provider key in Settings first.", error: true); return }
        let history = chat
        let user = ChatMessage(role: .user, text: q)
        chat.append(user); try? db.put("chat", id: user.id, sort: user.date.timeIntervalSince1970, user)
        var reply = ChatMessage(role: .assistant, text: "")
        chat.append(reply)
        chatStreaming = true
        let full = context.snapshot(emailLimit: 15, storyLimit: 12, cite: true)
        let snap = full.text + (extraContext.isEmpty ? "" : "\n\nCURRENTLY OPEN:\n" + extraContext)
        Task {
            defer { chatStreaming = false }
            do {
                for try await chunk in intel.chat(context: snap, history: history, question: q, name: userName) {
                    reply.text += chunk
                    if let i = chat.lastIndex(where: { $0.id == reply.id }) { chat[i] = reply }
                }
                let r = Citations.resolve(reply.text, sources: full.sources)
                reply.text = r.text; reply.sources = r.cited.isEmpty ? nil : r.cited
                if let i = chat.lastIndex(where: { $0.id == reply.id }) { animated { chat[i] = reply } }
                try? db.put("chat", id: reply.id, sort: Date().timeIntervalSince1970, reply)
            } catch {
                if reply.text.isEmpty { chat.removeAll { $0.id == reply.id } }
                fail(error, "Assistant")
            }
        }
    }

    func open(_ s: ChatSource) {
        switch s.kind {
        case .mail: section = .inbox; selectedBundleID = nil; selectedThread = s.ref
        case .news: section = .news; selectedStoryID = s.ref
        }
    }

    func clearChat() { chat = []; try? db.deleteAll("chat") }

    // MARK: Privacy

    func wipeAll() {
        mail.disconnect(wipe: true)
        try? db.wipeEverything()
        interests.reset()
        for p in ProviderID.allCases { Keychain.delete(KeychainAccount.aiKey(p.rawValue)) }
        Keychain.delete(KeychainAccount.googleClientSecret)
        prefs.resetAll()
        reloadLocal(); chat = []
        showOnboarding = true
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general = "General", briefing = "Briefing", voice = "Voice", accounts = "Accounts", ai = "AI provider", sources = "News sources", interests = "Interests", privacy = "Privacy", notifications = "Notifications", appearance = "Appearance", widgets = "Widgets", sync = "Sync", advanced = "Advanced"
    var id: String { rawValue }
}

enum InboxFilter: String, CaseIterable, Identifiable {
    case priority = "Priority", needsReply = "Needs reply", deadlines = "Deadlines", newsletters = "Newsletters", all = "All"
    var id: String { rawValue }
}
