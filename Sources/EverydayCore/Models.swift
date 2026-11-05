import Foundation

// MARK: Mail

public struct EmailMessage: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var threadId: String
    public var fromName: String
    public var fromAddress: String
    public var to: String
    public var subject: String
    public var snippet: String
    public var body: String
    public var date: Date
    public var labelIds: [String]
    public var hasAttachments: Bool
    public var messageIdHeader: String
    public var listUnsubscribe: String? = nil
    /// Stored as an optional so mail saved by older versions (without this key) still decodes.
    public var storedAttachments: [String]? = nil
    public var attachmentNames: [String] { get { storedAttachments ?? [] } set { storedAttachments = newValue.isEmpty ? nil : newValue } }
    /// The address of the account this came from. Mail stored before multiple accounts has none and belongs to the first account.
    public var account: String? = nil

    public var isUnread: Bool { labelIds.contains("UNREAD") }
    public var inInbox: Bool { labelIds.contains("INBOX") }

    public init(id: String, threadId: String, fromName: String, fromAddress: String, to: String, subject: String, snippet: String, body: String, date: Date, labelIds: [String], hasAttachments: Bool, messageIdHeader: String = "") {
        self.id = id; self.threadId = threadId; self.fromName = fromName; self.fromAddress = fromAddress; self.to = to
        self.subject = subject; self.snippet = snippet; self.body = body; self.date = date; self.labelIds = labelIds
        self.hasAttachments = hasAttachments; self.messageIdHeader = messageIdHeader
    }
}

public enum TriageCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    case important, needsReply, deadline, actionItem, newsletter, promo, spamSuspect, fyi
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .important: "Important"
        case .needsReply: "Needs reply"
        case .deadline: "Deadline"
        case .actionItem: "Action item"
        case .newsletter: "Newsletter"
        case .promo: "Promotion"
        case .spamSuspect: "Possible spam"
        case .fyi: "FYI"
        }
    }
}

public struct Triage: Codable, Hashable, Sendable {
    public var messageId: String
    public var category: TriageCategory
    public var priority: Int          // 0-100
    public var summary: String
    public var deadline: Date?
    public var actionItems: [String]
    public var needsReply: Bool
    public var promptVersion: Int
    public init(messageId: String, category: TriageCategory, priority: Int, summary: String, deadline: Date? = nil, actionItems: [String] = [], needsReply: Bool = false, promptVersion: Int = Triage.currentPromptVersion) {
        self.messageId = messageId; self.category = category; self.priority = priority; self.summary = summary
        self.deadline = deadline; self.actionItems = actionItems; self.needsReply = needsReply; self.promptVersion = promptVersion
    }
    public static let currentPromptVersion = 1
}

public struct ThreadSummary: Codable, Hashable, Sendable {
    public var threadId: String
    public var text: String
    public var messageCount: Int
}

public struct ReplyDraft: Codable, Hashable, Sendable, Identifiable {
    public var id: String { threadId + tone }
    public var threadId: String
    public var tone: String
    public var text: String
}

// MARK: Tasks

public enum TaskPriority: Int, Codable, CaseIterable, Sendable, Identifiable {
    case low = 0, medium = 1, high = 2
    public var id: Int { rawValue }
    public var title: String { ["Low", "Medium", "High"][rawValue] }
}

public enum TaskSource: String, Codable, Sendable { case manual, email, ai }

public struct TaskItem: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var notes: String
    public var due: Date?
    public var priority: TaskPriority
    public var source: TaskSource
    public var sourceDescription: String
    public var threadId: String?
    public var completedAt: Date?
    public var createdAt: Date
    public var reminderIdentifier: String?
    public var repeats: TaskRepeat? = nil

    public var isDone: Bool { completedAt != nil }

    public init(id: String = UUID().uuidString, title: String, notes: String = "", due: Date? = nil, priority: TaskPriority = .medium, source: TaskSource = .manual, sourceDescription: String = "", threadId: String? = nil, completedAt: Date? = nil, createdAt: Date = Date(), reminderIdentifier: String? = nil) {
        self.id = id; self.title = title; self.notes = notes; self.due = due; self.priority = priority; self.source = source
        self.sourceDescription = sourceDescription; self.threadId = threadId; self.completedAt = completedAt
        self.createdAt = createdAt; self.reminderIdentifier = reminderIdentifier
    }
}

public struct TaskSuggestion: Codable, Identifiable, Hashable, Sendable {
    public var id: String          // stable: messageId + title hash
    public var title: String
    public var due: Date?
    public var priority: TaskPriority
    public var sourceDescription: String
    public var threadId: String?
    public var dismissed: Bool
    public init(id: String, title: String, due: Date?, priority: TaskPriority, sourceDescription: String, threadId: String?, dismissed: Bool) {
        self.id = id; self.title = title; self.due = due; self.priority = priority; self.sourceDescription = sourceDescription; self.threadId = threadId; self.dismissed = dismissed
    }
}

// MARK: News

public enum NewsCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    case politics, technology, ai, science, gaming, business, world, aviation, entertainment, australia
    case health, climate, space, sport, economy, design, music, film, books, food, travel
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .health: "Health"
        case .climate: "Climate and environment"
        case .space: "Space"
        case .sport: "Sport"
        case .economy: "Economy"
        case .design: "Design and architecture"
        case .music: "Music"
        case .film: "Film and TV"
        case .books: "Books"
        case .food: "Food"
        case .travel: "Travel"
        case .politics: "Politics"
        case .technology: "Technology"
        case .ai: "AI"
        case .science: "Science"
        case .gaming: "Gaming"
        case .business: "Business"
        case .world: "World affairs"
        case .aviation: "Aviation"
        case .entertainment: "Entertainment"
        case .australia: "Australia"
        }
    }
}

public struct FeedSource: Codable, Identifiable, Hashable, Sendable {
    public var id: String { url }
    public var name: String
    public var url: String
    public var categories: [NewsCategory]
    public var trust: Int            // 1-3
    public var enabled: Bool
    public var outsideBubble: Bool
    public init(name: String, url: String, categories: [NewsCategory], trust: Int = 2, enabled: Bool = true, outsideBubble: Bool = false) {
        self.name = name; self.url = url; self.categories = categories; self.trust = trust; self.enabled = enabled; self.outsideBubble = outsideBubble
    }
}

public struct Article: Codable, Identifiable, Hashable, Sendable {
    public var id: String            // hash of canonical url
    public var title: String
    public var link: String
    public var source: String
    public var feedURL: String
    public var summary: String       // feed description, plain text
    public var imageURL: String?
    public var published: Date
    public var categories: [NewsCategory]
    public var trust: Int
    public var outsideBubble: Bool
    public init(id: String, title: String, link: String, source: String, feedURL: String, summary: String, imageURL: String?, published: Date, categories: [NewsCategory], trust: Int, outsideBubble: Bool) {
        self.id = id; self.title = title; self.link = link; self.source = source; self.feedURL = feedURL; self.summary = summary
        self.imageURL = imageURL; self.published = published; self.categories = categories; self.trust = trust; self.outsideBubble = outsideBubble
    }
}

public struct Story: Identifiable, Hashable, Sendable {
    public var id: String { lead.id }
    public var lead: Article
    public var others: [Article]
    public var score: Double
    public init(lead: Article, others: [Article], score: Double) { self.lead = lead; self.others = others; self.score = score }
    public var sources: [String] { ([lead] + others).map(\.source).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } } }
    public var categories: [NewsCategory] { lead.categories }
}

public struct ArticleAI: Codable, Hashable, Sendable {
    public var articleId: String
    public var summary: String
    public var whyItMatters: String
}

public enum Reaction: Int, Codable, Sendable { case dislike = -1, like = 1, love = 3 }

// MARK: Briefing / weather

public struct WeatherNow: Codable, Hashable, Sendable {
    public var city: String
    public var temperature: Double
    public var high: Double
    public var low: Double
    public var condition: String
    public var hourly: [HourPoint]
    public struct HourPoint: Codable, Hashable, Sendable { public var date: Date; public var temp: Double }
}

public struct CalendarEvent: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
}

public struct Briefing: Codable, Hashable, Sendable {
    public var generatedAt: Date
    public var text: String
    public var model: String
    public var emailCount: Int
    public var storyCount: Int
    public var eventCount: Int
    public var replies: [QuickReply]? = nil
    /// The full-length text while a shorter version is shown, so it can be restored without asking the AI again.
    public var fullText: String? = nil
}

/// A one-tap reply to the briefing. Each one only does something local and visible when pressed.
public struct QuickReply: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case handled, ignore, task, remind, ask }
    public var id: String
    public var label: String
    public var kind: Kind
    public var messageIds: [String]
    public var text: String
    public init(id: String = UUID().uuidString, label: String, kind: Kind, messageIds: [String] = [], text: String = "") {
        self.id = id; self.label = label; self.kind = kind; self.messageIds = messageIds; self.text = text
    }
}

/// "Treat mail like this as handled." Local only: never changes anything in the mail account.
public struct MailRule: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var senderContains: String
    public var subjectContains: String
    public var createdAt: Date
    public init(id: String = UUID().uuidString, senderContains: String, subjectContains: String, createdAt: Date = Date()) {
        self.id = id; self.senderContains = senderContains.lowercased(); self.subjectContains = subjectContains.lowercased(); self.createdAt = createdAt
    }
    public func matches(_ m: EmailMessage) -> Bool {
        let sender = (m.fromAddress + " " + m.fromName).lowercased()
        if !senderContains.isEmpty && !sender.contains(senderContains) { return false }
        if !subjectContains.isEmpty && !m.subject.lowercased().contains(subjectContains) { return false }
        return !senderContains.isEmpty || !subjectContains.isEmpty
    }
    public var summary: String {
        [senderContains.isEmpty ? nil : "from \(senderContains)", subjectContains.isEmpty ? nil : "subject has “\(subjectContains)”"].compactMap { $0 }.joined(separator: " and ")
    }
}

/// Something the assistant relied on, so the reader can open it.
public struct ChatSource: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case mail, news }
    public var tag: String; public var title: String; public var kind: Kind; public var ref: String
    public var id: String { tag }
    public init(tag: String, title: String, kind: Kind, ref: String) { self.tag = tag; self.title = title; self.kind = kind; self.ref = ref }
}

public struct ChatMessage: Codable, Identifiable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public var id: String
    public var role: Role
    public var text: String
    public var date: Date
    public var sources: [ChatSource]? = nil
    public init(id: String = UUID().uuidString, role: Role, text: String, date: Date = Date()) {
        self.id = id; self.role = role; self.text = text; self.date = date
    }
}


/// A conversation put away until a chosen time. Local only: nothing changes in the mail account.
public struct Snooze: Codable, Hashable, Sendable {
    public var threadId: String
    public var until: Date
    public var taskId: String?
    public var notified: Bool
    public init(threadId: String, until: Date, taskId: String? = nil, notified: Bool = false) { self.threadId = threadId; self.until = until; self.taskId = taskId; self.notified = notified }
}

/// Where a newsletter's "unsubscribe" header points. Nothing is opened or sent until the reader approves.
public struct UnsubscribeTarget: Equatable, Sendable {
    public var web: URL?
    public var mailto: String?
    public var host: String { web?.host ?? mailto?.split(separator: "@").last.map(String.init) ?? "the sender" }
    public static func parse(_ header: String?) -> UnsubscribeTarget? {
        guard let h = header, !h.isEmpty else { return nil }
        var t = UnsubscribeTarget()
        for part in h.components(separatedBy: "<").dropFirst() {
            let item = part.components(separatedBy: ">").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if item.lowercased().hasPrefix("https://"), t.web == nil, let u = URL(string: item) { t.web = u }
            else if item.lowercased().hasPrefix("mailto:"), t.mailto == nil { t.mailto = String(item.dropFirst(7)) }
        }
        return t.web == nil && t.mailto == nil ? nil : t
    }
}


/// How often a task comes back after it is completed.
public enum TaskRepeat: String, Codable, CaseIterable, Identifiable, Sendable {
    case daily, weekdays, weekly, monthly, yearly
    public var id: String { rawValue }
    public var title: String { switch self { case .daily: return "Every day"; case .weekdays: return "Every weekday"; case .weekly: return "Every week"; case .monthly: return "Every month"; case .yearly: return "Every year" } }

    /// The next due date after `due` (or after now when there is none), always in the future.
    public func next(after due: Date?, now: Date = Date(), calendar: Calendar = .current) -> Date {
        var d = due ?? now
        func step(_ x: Date) -> Date {
            switch self {
            case .daily: return calendar.date(byAdding: .day, value: 1, to: x) ?? x
            case .weekly: return calendar.date(byAdding: .weekOfYear, value: 1, to: x) ?? x
            case .monthly: return calendar.date(byAdding: .month, value: 1, to: x) ?? x
            case .yearly: return calendar.date(byAdding: .year, value: 1, to: x) ?? x
            case .weekdays:
                var n = calendar.date(byAdding: .day, value: 1, to: x) ?? x
                while calendar.isDateInWeekend(n) { n = calendar.date(byAdding: .day, value: 1, to: n) ?? n }
                return n
            }
        }
        d = step(d)
        var guardCount = 0
        while d <= now && guardCount < 800 { d = step(d); guardCount += 1 }
        return d
    }
}
