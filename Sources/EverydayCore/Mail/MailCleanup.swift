import Foundation

/// A description of a kind of email, written by the AI from what the person typed ("delete LinkedIn notifications older than a week").
/// It is only a filter: the AI never acts on mail. Matching happens locally, and nothing changes until the person approves the plan and presses a button.
public struct MailQuery: Codable, Hashable, Sendable {
    public enum Action: String, Codable, Sendable { case trash, archive }

    public var action: Action
    /// Any of these in the sender's name or address (OR).
    public var senders: [String] = []
    /// Any of these in the subject (OR).
    public var subjects: [String] = []
    /// Any of these in the subject, snippet or body (OR).
    public var words: [String] = []
    /// Any of these triage categories (OR), e.g. newsletter, promo, fyi.
    public var categories: [TriageCategory] = []
    public var olderThanDays: Int? = nil
    public var unreadOnly: Bool = false
    /// Only mail sent by machines (no-reply senders, mailing lists).
    public var automatedOnly: Bool = false
    /// The AI's one-line reading of the request, shown to the person.
    public var summary: String = ""

    public init(action: Action, senders: [String] = [], subjects: [String] = [], words: [String] = [], categories: [TriageCategory] = [], olderThanDays: Int? = nil, unreadOnly: Bool = false, automatedOnly: Bool = false, summary: String = "") {
        self.action = action; self.senders = senders; self.subjects = subjects; self.words = words; self.categories = categories
        self.olderThanDays = olderThanDays; self.unreadOnly = unreadOnly; self.automatedOnly = automatedOnly; self.summary = summary
    }

    /// A filter must say something about which mail it means; "everything" is never a valid plan.
    public var isSpecific: Bool { !senders.isEmpty || !subjects.isEmpty || !words.isEmpty || !categories.isEmpty }

    public func matches(_ m: EmailMessage, triage: Triage?, now: Date = Date()) -> Bool {
        guard isSpecific else { return false }
        func any(_ list: [String], in text: String) -> Bool { let t = text.lowercased(); return list.contains { !$0.isEmpty && t.contains($0.lowercased()) } }
        if !senders.isEmpty && !any(senders, in: m.fromName + " " + m.fromAddress) { return false }
        if !subjects.isEmpty && !any(subjects, in: m.subject) { return false }
        if !words.isEmpty && !any(words, in: m.subject + " " + m.snippet + " " + m.body) { return false }
        // Categories narrow sorted mail. Mail not sorted yet still counts when a sender, subject or word already picked it out.
        if !categories.isEmpty {
            if let c = triage?.category { guard categories.contains(c) else { return false } }
            else if senders.isEmpty && subjects.isEmpty && words.isEmpty { return false }
        }
        if let d = olderThanDays, now.timeIntervalSince(m.date) < Double(d) * 86400 { return false }
        if unreadOnly && !m.isUnread { return false }
        if automatedOnly && !Self.isAutomated(m) { return false }
        return true
    }

    static func isAutomated(_ m: EmailMessage) -> Bool {
        let a = m.fromAddress.lowercased()
        return m.listUnsubscribe != nil || ["noreply", "no-reply", "donotreply", "do-not-reply", "notifications@", "notification@", "alerts@", "mailer", "bounce", "updates@", "news@", "info@"].contains { a.contains($0) }
    }

    /// The plan in plain words: "Delete mail from linkedin, older than 7 days."
    public var plainDescription: String {
        var parts: [String] = []
        if !senders.isEmpty { parts.append("from " + Self.orList(senders)) }
        if !subjects.isEmpty { parts.append("with " + Self.orList(subjects.map { "“\($0)”" }) + " in the subject") }
        if !words.isEmpty { parts.append("mentioning " + Self.orList(words.map { "“\($0)”" })) }
        if !categories.isEmpty { parts.append("sorted as " + Self.orList(categories.map { $0.title.lowercased() })) }
        if automatedOnly { parts.append("sent automatically") }
        if unreadOnly { parts.append("still unread") }
        if let d = olderThanDays { parts.append(d == 1 ? "older than a day" : "older than \(d) days") }
        return (action == .trash ? "Move to Trash" : "Archive") + " mail " + parts.joined(separator: ", ") + "."
    }

    static func orList(_ xs: [String]) -> String { xs.count <= 1 ? (xs.first ?? "") : xs.dropLast().joined(separator: ", ") + " or " + xs.last! }
}

/// What a query would touch, and what was kept back for safety.
public struct CleanupPlan: Sendable, Identifiable {
    public let id = UUID()
    public var query: MailQuery
    public var rows: [MailRow]
    /// Matches left out because they look important: starred, VIP, a deadline, waiting on a reply, or sorted as important.
    public var protected: [MailRow]
}

/// A saved cleanup the person chose to keep. It never runs by itself: matching mail is offered for review in the inbox.
public struct CleanupRule: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var query: MailQuery
    public var createdAt: Date
    public init(id: String = UUID().uuidString, query: MailQuery, createdAt: Date = Date()) { self.id = id; self.query = query; self.createdAt = createdAt }
}

extension MailService {
    public static let cleanupLimit = 500

    /// Mail in the inbox matching the query, one row per conversation, newest first. Important-looking mail is set aside, not included.
    public func cleanupPlan(_ q: MailQuery, now: Date = Date()) -> CleanupPlan {
        let tri = allTriage()
        var seen = Set<String>(), keep: [MailRow] = [], held: [MailRow] = []
        for m in emails(limit: 5000).sorted(by: { $0.date > $1.date }) where !seen.contains(m.threadId) {
            let t = tri[m.id]
            guard q.matches(m, triage: t, now: now) else { continue }
            seen.insert(m.threadId)
            let row = MailRow(message: m, triage: t, threadCount: 1)
            if isProtected(m, triage: t) { held.append(row) } else if keep.count < Self.cleanupLimit { keep.append(row) }
        }
        return CleanupPlan(query: q, rows: keep, protected: held)
    }

    func isProtected(_ m: EmailMessage, triage t: Triage?) -> Bool {
        if m.labelIds.contains("STARRED") || m.labelIds.contains("\\Flagged") || m.labelIds.contains("FLAGGED") || m.labelIds.contains("IMPORTANT") && t?.category == .important { return true }
        if isVIP(m.fromAddress) { return true }
        if let t, t.deadline != nil || t.needsReply || t.category == .important || t.category == .deadline { return true }
        return false
    }

    public func cleanupRules() -> [CleanupRule] { ((try? db.all("cleanupRule", limit: 200, as: CleanupRule.self)) ?? []).sorted { $0.createdAt > $1.createdAt } }
    public func saveCleanupRule(_ q: MailQuery) { let r = CleanupRule(query: q); try? db.put("cleanupRule", id: r.id, sort: r.createdAt.timeIntervalSince1970, r) }
    public func removeCleanupRule(_ r: CleanupRule) { try? db.delete("cleanupRule", id: r.id) }

    /// Saved cleanups with mail waiting for review.
    public func pendingCleanups() -> [CleanupPlan] { cleanupRules().map { cleanupPlan($0.query) }.filter { !$0.rows.isEmpty } }

    /// Turns what the person typed into a filter. Throws when the request is not about clearing out mail or is too vague to be safe.
    public func understandCleanup(_ request: String) async throws -> MailQuery { try await intel.mailQuery(request) }
}

public enum CleanupError: Error, LocalizedError {
    case unclear(String)
    public var errorDescription: String? { if case .unclear(let s) = self { return s }; return nil }
}

extension Intelligence {
    public func mailQuery(_ request: String) async throws -> MailQuery {
        let system = """
        You turn a person's request about clearing out their email into a filter. You never act on mail yourself; the person reviews and approves every change. Now is \(Self.dateString(Date())).
        Return one JSON object: {"action": "trash" if they say delete, remove, bin or trash, otherwise "archive", "senders": [short distinctive pieces of sender names, domains or addresses, lowercase, e.g. "linkedin", "github.com"], "subjects": [phrases that appear in the subject], "words": [phrases that appear anywhere in the email; use sparingly], "categories": [any of "newsletter", "promo", "fyi", "spamSuspect"], "olderThanDays": number or null, "unreadOnly": bool, "automatedOnly": bool (true when they mean notifications, alerts or automated mail), "summary": "one short plain sentence saying what you understood", "unclear": null, or a short question if the request is not about clearing out email or is too vague to pick mail safely}.
        Never return a filter that would match all mail. Prefer senders and subjects over words. For "CI failures" use subjects such as "run failed", "failed", "build failed" with automatedOnly true. Use only fields that the request implies.
        """
        let out = try await ai.complete(.triage, label: "Understand inbox cleanup", AIRequest(system: system, messages: [AIMessage(.user, "<data>\n\(request)\n</data>")], maxTokens: 500, temperature: 0.1, json: true))
        return try Self.parseMailQuery(out)
    }

    public static func parseMailQuery(_ text: String) throws -> MailQuery {
        guard let d = extractJSON(text), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { throw AIError.badResponse("cleanup filter was not JSON") }
        if let q = o["unclear"] as? String, !q.trimmingCharacters(in: .whitespaces).isEmpty { throw CleanupError.unclear(q) }
        func list(_ k: String) -> [String] { ((o[k] as? [Any]) ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count >= 2 }.prefix(8).map { $0 } }
        let q = MailQuery(
            action: (o["action"] as? String) == "trash" ? .trash : .archive,
            senders: list("senders"), subjects: list("subjects"), words: list("words"),
            // Only low-stakes categories can be targeted by kind; important mail is never a category to clear.
            categories: list("categories").compactMap(TriageCategory.init(rawValue:)).filter { [.newsletter, .promo, .fyi, .spamSuspect].contains($0) },
            olderThanDays: (o["olderThanDays"] as? NSNumber).map { max(0, $0.intValue) },
            unreadOnly: (o["unreadOnly"] as? Bool) ?? false, automatedOnly: (o["automatedOnly"] as? Bool) ?? false,
            summary: ((o["summary"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        guard q.isSpecific else { throw CleanupError.unclear("Which emails do you mean? Name a sender, a subject or a kind of mail, like newsletters.") }
        return q
    }
}
