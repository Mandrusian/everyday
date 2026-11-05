import Foundation

/// Assembles a plain-text snapshot of the user's world. Used by the briefing and the assistant.
public struct ContextBuilder {
    public let mail: MailService
    public let tasks: TaskStore
    public let news: NewsService
    public let weather: WeatherService
    public let calendar: CalendarService
    public var prefs: Prefs = .shared
    public init(mail: MailService, tasks: TaskStore, news: NewsService, weather: WeatherService, calendar: CalendarService, prefs: Prefs = .shared) {
        self.mail = mail; self.tasks = tasks; self.news = news; self.weather = weather; self.calendar = calendar; self.prefs = prefs
    }

    public static let allSections = ["mail", "calendar", "weather", "news", "tasks"]
    public func includes(_ section: String) -> Bool {
        let chosen = prefs.strings(Prefs.Key.briefingSections)
        return chosen.isEmpty ? true : chosen.contains(section)
    }

    static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE d MMM HH:mm"; return f }()

    public func snapshot(emailLimit: Int = 12, storyLimit: Int = 10, cite: Bool = false) -> (text: String, emails: Int, stories: Int, events: Int, sources: [ChatSource]) {
        var out: [String] = []
        var sources: [ChatSource] = []
        let rows = (includes("mail") ? mail.rows() : []).filter { r in
            guard let t = r.triage else { return false }
            return t.category != .newsletter && t.category != .promo && t.category != .spamSuspect && t.priority >= 40
        }.prefix(emailLimit)
        if !rows.isEmpty {
            out.append("EMAIL NEEDING ATTENTION (priority-ordered):")
            for (i, r) in rows.enumerated() {
                let t = r.triage!
                if cite { sources.append(ChatSource(tag: "M\(i + 1)", title: "\(r.message.fromName): \(r.message.subject)", kind: .mail, ref: r.message.threadId)) }
                var line = "- \(cite ? "[M\(i + 1)] " : "")[\(t.category.title), priority \(t.priority)] \(r.message.fromName): \(r.message.subject) — \(t.summary)"
                if let d = t.deadline { line += " (deadline \(Self.time.string(from: d)))" }
                if t.needsReply { line += " (reply owed)" }
                out.append(line)
            }
        }
        let handled = includes("mail") ? mail.handledSummaries() : []
        if !handled.isEmpty {
            out.append("\nALREADY HANDLED BY THE READER (they said these were them or do not matter; never mention these senders or anything like them):")
            for h in handled { out.append("- \(h.sender): \(h.subject)") }
        }
        let open = (includes("tasks") ? tasks.open() : []).prefix(12)
        if !open.isEmpty {
            out.append("\nOPEN TASKS:")
            for t in open { out.append("- \(t.title)\(t.due.map { " (due \(Self.time.string(from: $0)))" } ?? "") [\(t.priority.title) priority]") }
        }
        let events = includes("calendar") ? calendar.upcoming() : []
        if !events.isEmpty {
            out.append("\nCALENDAR:")
            for e in events.prefix(10) { out.append("- \(e.isAllDay ? "All day" : Self.time.string(from: e.start)): \(e.title)") }
        }
        if includes("weather"), let w = weather.cached() {
            out.append("\nWEATHER in \(w.city): \(Int(w.temperature.rounded()))°C now, \(w.condition.lowercased()), high \(Int(w.high.rounded()))° low \(Int(w.low.rounded()))°.")
        }
        let newsCount = includes("news") ? Int(prefs.double(Prefs.Key.briefingNewsCount, default: Double(storyLimit > 5 ? 4 : storyLimit))) : 0
        let stories = newsCount > 0 ? news.stories(limit: min(storyLimit, newsCount)) : []
        if !stories.isEmpty {
            out.append("\nTOP NEWS:")
            for (i, s) in stories.enumerated() {
                if cite { sources.append(ChatSource(tag: "N\(i + 1)", title: s.lead.title, kind: .news, ref: s.id)) }
                out.append("- \(cite ? "[N\(i + 1)] " : "")\(s.lead.title) (\(s.sources.prefix(4).joined(separator: ", "))) — \(String(s.lead.summary.prefix(200)))")
            }
        }
        return (out.joined(separator: "\n"), rows.count, stories.count, events.count, sources)
    }
}

public final class BriefingService: @unchecked Sendable {
    private let db: Database
    private let intel: Intelligence
    private let ctx: ContextBuilder
    public init(db: Database, intelligence: Intelligence, context: ContextBuilder) { self.db = db; self.intel = intelligence; self.ctx = context }

    /// Names of handled senders that no still-open item shares (so handling one Google notice never hides a real person called Google).
    static func bannedNames(_ mail: MailService) -> [String] {
        let open = Set(mail.attention(limit: 50).map { $0.message.fromName.lowercased() })
        var seen = Set<String>(), out: [String] = []
        for h in mail.handledSummaries(limit: 20) {
            let n = h.sender.trimmingCharacters(in: .whitespaces)
            if n.count >= 3, !n.contains("@"), !open.contains(n.lowercased()), seen.insert(n.lowercased()).inserted { out.append(n) }
        }
        return out
    }
    static func mentions(_ text: String, _ names: [String]) -> [String] {
        let plain = SkimMarkup.strip(text).lowercased()
        return names.filter { plain.contains($0.lowercased()) }
    }
    /// Instantly drops sentences about things the reader has just handled, before any rewrite finishes.
    public func scrubbed(_ b: Briefing) -> Briefing {
        var x = b; x.text = Briefing.removingSentences(mentioning: Self.bannedNames(ctx.mail), from: b.text)
        if x.text != b.text { x.replies = nil; save(x) }
        return x
    }
    public func save(_ b: Briefing) { try? db.put("briefing", id: "latest", b) }

    public func latest() -> Briefing? { try? db.get("briefing", id: "latest") }

    /// Streams the briefing: `onPartial` receives the full text so far, as it is written.
    public func generate(name: String, onPartial: (@Sendable (String) -> Void)? = nil) async throws -> Briefing {
        let snap = ctx.snapshot()
        guard !snap.text.isEmpty else { throw AIError.badResponse("There is nothing to brief yet. Connect mail or refresh the news first.") }
        var text = ""
        let banned = Self.bannedNames(ctx.mail)
        for attempt in 0..<2 {
            text = ""
            let hint = attempt == 0 ? "" : "\n\nYour previous draft mentioned \(banned.joined(separator: ", ")), which the reader has already handled. Write it again without any mention of them."
            for try await chunk in intel.briefingStream(context: snap.text + hint, name: name) { text += chunk; onPartial?(text) }
            if Self.mentions(text, banned).isEmpty { break }
        }
        // Whatever the model did, handled senders never appear: drop any sentence that still names one.
        text = Briefing.removingSentences(mentioning: banned, from: text)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines).skimLimited(8)
        if intel.skimOn {
            // The model sometimes skips the tags on long inputs; highlight dates, amounts and urgent words locally instead.
            if !SkimMarkup.hasTags(text) {
                text = SkimMarkup.autoTag(text, names: ctx.mail.attention(limit: 6).map(\.message.fromName), places: [ctx.weather.city])
            }
        } else { text = SkimMarkup.strip(text) }
        let b = Briefing(generatedAt: Date(), text: text, model: intel.ai.model(for: .summary), emailCount: snap.emails, storyCount: snap.stories, eventCount: snap.events)
        try? db.put("briefing", id: "latest", b)
        return b
    }

    public func attentionItems(limit: Int = 8) -> [Intelligence.AttentionItem] {
        ctx.mail.attention(limit: limit).map { r in
            let t = r.triage
            var line = "\(r.message.fromName): \(t?.summary.isEmpty == false ? t!.summary : r.message.subject)"
            if let d = t?.deadline { line += " (deadline \(ContextBuilder.time.string(from: d)))" }
            return Intelligence.AttentionItem(id: r.message.id, text: line)
        }
    }

    /// Adds AI-suggested one-tap replies to the stored briefing.
    public func loadReplies(for b: Briefing) async -> Briefing {
        let items = attentionItems()
        guard !items.isEmpty, let replies = try? await intel.quickReplies(briefing: b.text, items: items), !replies.isEmpty else { return b }
        var x = b; x.replies = replies
        try? db.put("briefing", id: "latest", x)
        return x
    }

    public func isStale(hour: Int) -> Bool {
        guard let b = latest() else { return true }
        let cal = Calendar.current
        if !cal.isDateInToday(b.generatedAt) { return cal.component(.hour, from: Date()) >= hour }
        return false
    }
}


extension Briefing {
    /// Removes every sentence that mentions any of the names (case-insensitive, ignoring highlight tags).
    public static func removingSentences(mentioning names: [String], from text: String) -> String {
        let names = names.map { $0.lowercased() }.filter { !$0.isEmpty }
        guard !names.isEmpty else { return text }
        var sentences: [String] = [], cur = ""
        for ch in text { cur.append(ch); if ".!?".contains(ch) { sentences.append(cur); cur = "" } }
        if !cur.isEmpty { sentences.append(cur) }
        let kept = sentences.filter { s in let plain = SkimMarkup.strip(s).lowercased(); return !names.contains { plain.contains($0) } }
        return kept.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}


/// When the morning briefing notification is due: once per day, from the chosen hour, even if the app opens later that day.
public enum BriefingSchedule {
    public static func dayKey(_ d: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d); return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }
    public static func shouldSend(now: Date, hour: Int, lastSent: String, calendar: Calendar = .current) -> Bool {
        guard calendar.component(.hour, from: now) >= hour else { return false }
        return lastSent != dayKey(now, calendar: calendar)
    }
    /// A short notification body: the first sentence or two of the briefing, without highlight tags.
    public static func preview(_ text: String, limit: Int = 150) -> String {
        let plain = SkimMarkup.strip(text).replacingOccurrences(of: "\n", with: " ")
        if plain.count <= limit { return plain }
        let cut = String(plain.prefix(limit))
        if let end = cut.lastIndex(where: { ".!?".contains($0) }) { return String(cut[...end]) }
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }
}


public enum Citations {
    /// Cited sources in the order they first appear, and the text with the bracketed tags removed.
    public static func resolve(_ text: String, sources: [ChatSource]) -> (text: String, cited: [ChatSource]) {
        guard let re = try? NSRegularExpression(pattern: #"\s?\[((?:[MN]\d+)(?:\s*,\s*[MN]\d+)*)\]"#) else { return (text, []) }
        let ns = text as NSString
        var cited: [ChatSource] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            for tag in ns.substring(with: m.range(at: 1)).split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                if let s = sources.first(where: { $0.tag == tag }), !cited.contains(s) { cited.append(s) }
            }
        }
        let clean = re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        return (clean, cited)
    }
}
