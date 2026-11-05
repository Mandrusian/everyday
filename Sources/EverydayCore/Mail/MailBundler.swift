import Foundation

/// A group of repeated automated mail (security alerts, receipts, notifications) from one sender.
public struct MailBundle: Identifiable, Hashable, Sendable {
    public var id: String                 // stable for the same set of conversations
    public var title: String              // e.g. "Google"
    public var rows: [MailRow]            // newest first
    public var count: Int { rows.count }
    public var latest: Date { rows.map(\.message.date).max() ?? .distantPast }
    public var unread: Int { rows.filter { $0.message.isUnread }.count }
    public var priority: Int { rows.compactMap { $0.triage?.priority }.max() ?? 0 }
    public var category: TriageCategory? {
        let cats = rows.compactMap { $0.triage?.category }
        return Dictionary(grouping: cats, by: { $0 }).max { $0.value.count < $1.value.count }?.key
    }
    public var hasUrgent: Bool { rows.contains { MailService.isAttention($0) } }
}

public enum InboxItem: Identifiable, Hashable, Sendable {
    case thread(MailRow)
    case bundle(MailBundle)
    public var id: String { switch self { case .thread(let r): return r.id; case .bundle(let b): return "bundle:" + b.id } }
    public var priority: Int { switch self { case .thread(let r): return r.triage?.priority ?? -1; case .bundle(let b): return b.priority } }
    public var date: Date { switch self { case .thread(let r): return r.message.date; case .bundle(let b): return b.latest } }
}

public enum MailBundler {
    static let automatedLocal = try! NSRegularExpression(pattern: #"^(no[-_.]?reply|do[-_.]?not[-_.]?reply|notifications?|alerts?|security|mailer|mailer-daemon|updates?|news|newsletter|hello|team|info|support|billing|receipts?|digest|account|accounts)([-_.+].*)?$"#, options: [.caseInsensitive])

    /// True for mail sent by a system rather than a person.
    public static func isAutomated(_ m: EmailMessage, category: TriageCategory?) -> Bool {
        if let c = category, c == .newsletter || c == .promo { return true }
        let local = m.fromAddress.split(separator: "@").first.map(String.init) ?? ""
        return automatedLocal.firstMatch(in: local, range: NSRange(location: 0, length: (local as NSString).length)) != nil
    }

    /// Registrable-ish domain: accounts.google.com → google.com, mail.example.com.au → example.com.au
    public static func domainKey(_ address: String) -> String {
        let host = address.split(separator: "@").last.map { String($0).lowercased() } ?? address.lowercased()
        let parts = host.split(separator: ".").map(String.init)
        guard parts.count > 2 else { return host }
        let sld = ["com", "co", "org", "net", "gov", "edu"]
        return sld.contains(parts[parts.count - 2]) && parts.last!.count == 2 ? parts.suffix(3).joined(separator: ".") : parts.suffix(2).joined(separator: ".")
    }

    static func displayName(_ rows: [MailRow], domain: String) -> String {
        let names = rows.map { $0.message.fromName }.filter { !$0.contains("@") && !$0.isEmpty }
        if let common = Dictionary(grouping: names, by: { $0 }).max(by: { $0.value.count < $1.value.count })?.key { return common }
        return domain.split(separator: ".").first.map { String($0).capitalized } ?? domain
    }

    /// Groups automated senders with `minCount` or more conversations. People and one-off senders are never grouped.
    public static func bundles(from rows: [MailRow], minCount: Int = 3) -> [MailBundle] {
        var groups: [String: [MailRow]] = [:]
        for r in rows where isAutomated(r.message, category: r.triage?.category) { groups[domainKey(r.message.fromAddress), default: []].append(r) }
        return groups.filter { $0.value.count >= minCount }.map { key, rs in
            let sorted = rs.sorted { $0.message.date > $1.message.date }
            return MailBundle(id: Hashing.short(key + ":" + sorted.map(\.message.threadId).sorted().joined(separator: ",")), title: displayName(sorted, domain: key), rows: sorted)
        }
    }

    /// The inbox as a list of single threads and bundles, ordered by priority then recency.
    public static func items(from rows: [MailRow], minCount: Int = 3) -> [InboxItem] {
        let bs = bundles(from: rows, minCount: minCount)
        let inBundle = Set(bs.flatMap { $0.rows.map(\.id) })
        var items: [InboxItem] = rows.filter { !inBundle.contains($0.id) }.map { .thread($0) } + bs.map { .bundle($0) }
        items.sort { $0.priority != $1.priority ? $0.priority > $1.priority : $0.date > $1.date }
        return items
    }
}
