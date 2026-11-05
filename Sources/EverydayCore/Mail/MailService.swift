import Foundation

/// Proof that a person pressed a button. Mail write operations require one; the AI layer never has access to this type's callers.
public struct UserApproval: Sendable {
    public let at = Date()
    public static func fromUserAction() -> UserApproval { UserApproval() }
}

public struct MailRow: Identifiable, Hashable, Sendable {
    public var id: String { message.id }
    public var message: EmailMessage
    public var triage: Triage?
    public var threadCount: Int
    public init(message: EmailMessage, triage: Triage?, threadCount: Int) { self.message = message; self.triage = triage; self.threadCount = threadCount }
}

public final class MailService: @unchecked Sendable {
    private let db: Database
    public let auth: GoogleAuth
    public let gmail: GmailBackend
    public let imap: ImapBackend
    private let intel: Intelligence
    private let prefs: Prefs

    public init(db: Database, auth: GoogleAuth, intelligence: Intelligence, prefs: Prefs = .shared, imap: ImapBackend? = nil) {
        self.db = db; self.auth = auth; self.gmail = GmailBackend(auth: auth); self.imap = imap ?? ImapBackend(prefs: prefs)
        self.intel = intelligence; self.prefs = prefs
    }

    /// Which backend is active. Existing Gmail API sign-ins keep working; new setups use IMAP.
    public var kind: MailBackendKind {
        get {
            if let k = MailBackendKind(rawValue: prefs.string("mail.backend")) { return k }
            return gmail.isConnected ? .gmailAPI : .imap
        }
        set { prefs.set(newValue.rawValue, "mail.backend") }
    }
    public var backend: MailBackend { kind == .gmailAPI ? gmail : imap }
    public var isConnected: Bool { backend.isConnected }
    public var accountEmail: String? { backend.accountEmail }
    public var lastSync: Date? { (try? db.get("meta", id: "mailLastSync", as: Date.self)) }

    // MARK: Sync

    public func sync(progress: (@Sendable (String) -> Void)? = nil) async throws -> Int {
        guard isConnected else { return 0 }
        let days = Int(prefs.double(Prefs.Key.syncDays, default: 30))
        let state: String? = try db.get("meta", id: "mailSyncState")
        let known = emails(limit: 5000)
        let batch = try await backend.sync(days: days, known: known, state: state, progress: progress)
        for id in batch.removedIDs { removeLocal(id) }
        for m in batch.upserts { store(m) }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        _ = try? db.exec("DELETE FROM docs WHERE kind='email' AND sort < ?", [.double(cutoff.timeIntervalSince1970)])
        if let st = batch.state { try db.put("meta", id: "mailSyncState", st) }
        try db.put("meta", id: "mailLastSync", Date())
        return batch.upserts.count + batch.removedIDs.count
    }

    private func store(_ m: EmailMessage) {
        try? db.put("email", id: m.id, sort: m.date.timeIntervalSince1970, m)
        try? db.indexMail(id: m.id, subject: m.subject, sender: "\(m.fromName) \(m.fromAddress)", body: String(m.body.prefix(20000)))
    }

    private func removeLocal(_ id: String) {
        try? db.delete("email", id: id); try? db.delete("triage", id: id)
        _ = try? db.exec("DELETE FROM mail_fts WHERE id=?", [.text(id)])
    }

    public func disconnect(wipe: Bool) {
        if kind == .gmailAPI { gmail.signOut() } else { imap.remove() }
        prefs.remove("mail.backend")
        for k in ["mailSyncState", "mailHistoryId", "mailLastSync"] { try? db.delete("meta", id: k) }
        if wipe { for k in ["email", "triage", "threadSummary", "replyDraft", "taskSuggestion", "handledThread"] { try? db.deleteAll(k) }; _ = try? db.exec("DELETE FROM mail_fts") }
    }

    // MARK: Attachments

    static let unsafeExtensions: Set<String> = ["app", "command", "sh", "exe", "bat", "cmd", "com", "scr", "pkg", "dmg", "jar", "js", "vbs", "ps1", "msi", "dylib", "terminal", "workflow", "action", "scpt", "pif", "lnk", "iso", "apk", "ipa"]
    public static func isSafeToPreview(_ name: String) -> Bool { !unsafeExtensions.contains((name as NSString).pathExtension.lowercased()) }
    public static func safeFileName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: #"[/\\:\x00-\x1f]"#, with: "_", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return cleaned.isEmpty ? "attachment" : String(cleaned.prefix(120))
    }

    /// Downloads an attachment into a private cache folder and returns the file. Apps and scripts are refused.
    public func attachmentFile(_ m: EmailMessage, name: String) async throws -> URL {
        guard Self.isSafeToPreview(name) else { throw MailAttachmentError.unsafe(name) }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("everyday/attachments/\(Hashing.short(m.id))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(Self.safeFileName(name))
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let data = try await backend.attachmentData(m, name: name)
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: Snooze and VIP senders (local only)

    public func snoozes() -> [String: Snooze] { Dictionary(((try? db.all("snooze", limit: 2000, as: Snooze.self)) ?? []).map { ($0.threadId, $0) }, uniquingKeysWith: { a, _ in a }) }
    public func snooze(threadId: String, until: Date, taskId: String? = nil) { try? db.put("snooze", id: threadId, sort: until.timeIntervalSince1970, Snooze(threadId: threadId, until: until, taskId: taskId)) }
    public func clearSnooze(threadId: String) { try? db.delete("snooze", id: threadId) }
    public func snoozedCount() -> Int { snoozes().values.filter { $0.until > Date() }.count }
    /// Snoozes that have just come due and not yet been announced.
    public func dueSnoozes(now: Date = Date()) -> [Snooze] {
        let due = snoozes().values.filter { $0.until <= now && !$0.notified }
        for var s in due { s.notified = true; try? db.put("snooze", id: s.threadId, sort: s.until.timeIntervalSince1970, s) }
        return due
    }

    public func vips() -> [String] { ((try? db.all("vipSender", limit: 500, as: String.self)) ?? []).sorted() }
    public func isVIP(_ address: String) -> Bool { (try? db.get("vipSender", id: address.lowercased(), as: String.self)) != nil }
    public func setVIP(_ address: String, _ on: Bool) {
        let a = address.lowercased()
        if on { try? db.put("vipSender", id: a, sort: Date().timeIntervalSince1970, a) } else { try? db.delete("vipSender", id: a) }
    }

    // MARK: Rules and handled threads (local only)

    public func rules() -> [MailRule] { ((try? db.all("mailRule", limit: 500, as: MailRule.self)) ?? []).sorted { $0.createdAt > $1.createdAt } }
    public func removeRule(_ r: MailRule) { try? db.delete("mailRule", id: r.id) }
    private func handledThreads() -> Set<String> { Set(((try? db.all("handledThread", limit: 5000, as: String.self)) ?? [])) }

    /// "That was me": hides the conversation from attention lists and dismisses tasks suggested from it. Nothing changes in the mail account.
    public func markHandled(threadId: String) {
        try? db.put("handledThread", id: threadId, sort: Date().timeIntervalSince1970, threadId)
        clearSnooze(threadId: threadId)
        for s in suggestions() where s.threadId == threadId { dismiss(s) }
    }

    public func unhandle(threadId: String) { try? db.delete("handledThread", id: threadId) }

    /// "That was me" on automated mail covers every conversation from the same sender group (for example all Google account notices), not only the one that was pressed. People are never grouped.
    public func expandedThreadIDs(_ threadIds: [String]) -> [String] {
        let all = emails(limit: 1000), tri = allTriage()
        let byThread = Dictionary(grouping: all) { $0.threadId }
        func latest(_ id: String) -> EmailMessage? { byThread[id]?.max { $0.date < $1.date } }
        var keys = Set<String>()
        for id in threadIds { if let m = latest(id), MailBundler.isAutomated(m, category: tri[m.id]?.category) { keys.insert(MailBundler.domainKey(m.fromAddress)) } }
        var out = Set(threadIds)
        guard !keys.isEmpty else { return Array(out) }
        for (tid, _) in byThread { if let m = latest(tid), MailBundler.isAutomated(m, category: tri[m.id]?.category), keys.contains(MailBundler.domainKey(m.fromAddress)) { out.insert(tid) } }
        return Array(out)
    }

    /// What the reader has already dealt with, newest first, so a rewritten briefing can leave it out.
    public func handledSummaries(limit: Int = 10) -> [(sender: String, subject: String)] {
        let handled = handledThreads(), rl = rules()
        var seen = Set<String>(), out: [(String, String)] = []
        for m in emails(limit: 600).sorted(by: { $0.date > $1.date }) where handled.contains(m.threadId) || rl.contains(where: { $0.matches(m) }) {
            if seen.insert(m.threadId).inserted { out.append((m.fromName, m.subject)) }
            if out.count >= limit { break }
        }
        return out
    }

    /// Treat mail like this (same sender and similar subject) as handled from now on.
    @discardableResult
    public func ignoreSimilar(to m: EmailMessage) -> MailRule {
        let words = m.subject.lowercased().replacingOccurrences(of: #"[^a-z ]"#, with: " ", options: .regularExpression).split(separator: " ").map(String.init).filter { $0.count > 2 }
        let rule = MailRule(senderContains: m.fromAddress, subjectContains: words.prefix(3).joined(separator: " "))
        try? db.put("mailRule", id: rule.id, sort: rule.createdAt.timeIntervalSince1970, rule)
        markHandled(threadId: m.threadId)
        return rule
    }

    private func quieted(_ t: Triage) -> Triage {
        Triage(messageId: t.messageId, category: .fyi, priority: min(t.priority, 5), summary: t.summary, deadline: nil, actionItems: [], needsReply: false, promptVersion: t.promptVersion)
    }

    /// Conversations that need the user right now, highest priority first.
    public static func isAttention(_ r: MailRow) -> Bool {
        guard let t = r.triage else { return false }
        return (t.needsReply || t.deadline != nil || t.priority >= 75) && t.category != .newsletter && t.category != .promo && t.category != .fyi
    }
    public func attention(limit: Int = 3) -> [MailRow] { Array(rows().filter(Self.isAttention).prefix(limit)) }

    // MARK: Reading

    public func emails(limit: Int = 400) -> [EmailMessage] { ((try? db.all("email", limit: limit, as: EmailMessage.self)) ?? []).filter(\.inInbox) }
    public func triage(for id: String) -> Triage? { try? db.get("triage", id: id) }
    public func allTriage() -> [String: Triage] {
        let t: [Triage] = (try? db.all("triage", limit: 10000)) ?? []
        return Dictionary(t.map { ($0.messageId, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// One row per thread (latest message), sorted by AI priority then recency.
    public func rows(search: String = "") -> [MailRow] {
        let all = emails(limit: 1000)
        let tri = allTriage()
        let handled = handledThreads(), ruleList = rules()
        let snoozed = snoozes(), vipSet = Set(vips()), now = Date()
        var matching = Set<String>()
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { matching = Set((try? db.searchMail(q)) ?? []) }
        let byThread = Dictionary(grouping: all) { $0.threadId }
        var rows: [MailRow] = byThread.compactMap { (_, msgs) in
            guard let latest = msgs.max(by: { $0.date < $1.date }) else { return nil }
            if !q.isEmpty && !msgs.contains(where: { matching.contains($0.id) }) { return nil }
            let sn = snoozed[latest.threadId]
            if let sn, sn.until > now { return nil }                 // put away until later
            var t = tri[latest.id] ?? msgs.compactMap { tri[$0.id] }.max(by: { $0.priority < $1.priority })
            if vipSet.contains(latest.fromAddress.lowercased()) {    // VIP senders always rise to the top
                let b = t ?? Triage(messageId: latest.id, category: .important, priority: 95, summary: latest.subject, deadline: nil, actionItems: [], needsReply: false)
                t = Triage(messageId: b.messageId, category: [.newsletter, .promo, .fyi, .spamSuspect].contains(b.category) ? .important : b.category, priority: max(b.priority, 95), summary: b.summary, deadline: b.deadline, actionItems: b.actionItems, needsReply: b.needsReply, promptVersion: b.promptVersion)
            }
            if sn != nil, sn!.until <= now {                          // a snoozed conversation coming back needs you
                let b = t ?? Triage(messageId: latest.id, category: .needsReply, priority: 90, summary: latest.subject, deadline: nil, actionItems: [], needsReply: true)
                t = Triage(messageId: b.messageId, category: .needsReply, priority: max(b.priority, 90), summary: b.summary, deadline: b.deadline, actionItems: b.actionItems, needsReply: true, promptVersion: b.promptVersion)
            }
            if let x = t, handled.contains(latest.threadId) || ruleList.contains(where: { $0.matches(latest) }) { t = quieted(x) }
            return MailRow(message: latest, triage: t, threadCount: msgs.count)
        }
        rows.sort {
            let a = $0.triage?.priority ?? -1, b = $1.triage?.priority ?? -1
            if a != b { return a > b }
            return $0.message.date > $1.message.date
        }
        return rows
    }

    public func thread(_ threadId: String) -> [EmailMessage] {
        ((try? db.allWhere("email", field: "threadId", equals: threadId, as: EmailMessage.self)) ?? []).sorted { $0.date < $1.date }
    }

    // MARK: AI work

    /// Triage every unprocessed inbox message in batches. Returns the number processed.
    public func triagePending(progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> Int {
        let tri = allTriage()
        let pending = emails(limit: 400).filter { tri[$0.id]?.promptVersion != Triage.currentPromptVersion }
        guard !pending.isEmpty else { return 0 }
        var done = 0
        for batch in stride(from: 0, to: pending.count, by: 8).map({ Array(pending[$0..<min($0 + 8, pending.count)]) }) {
            let results = try await intel.triage(batch)
            for t in results {
                try? db.put("triage", id: t.messageId, sort: Double(t.priority), t)
                makeSuggestions(from: t, message: batch.first { $0.id == t.messageId })
            }
            done += batch.count
            progress?(done, pending.count)
        }
        return done
    }

    private func makeSuggestions(from t: Triage, message: EmailMessage?) {
        guard let m = message, t.category != .newsletter, t.category != .promo, t.category != .spamSuspect else { return }
        var titles = t.actionItems
        if t.needsReply && !titles.contains(where: { $0.lowercased().contains("repl") }) { titles.append("Reply to \(m.fromName)") }
        for title in titles.prefix(3) {
            let id = m.id + "." + String(abs(title.hashValue))
            if (try? db.get("taskSuggestion", id: id, as: TaskSuggestion.self)) != nil { continue }
            let pr: TaskPriority = t.priority >= 75 ? .high : t.priority >= 45 ? .medium : .low
            let s = TaskSuggestion(id: id, title: title, due: t.deadline, priority: pr, sourceDescription: "\(m.fromName): \(m.subject)", threadId: m.threadId, dismissed: false)
            try? db.put("taskSuggestion", id: id, sort: m.date.timeIntervalSince1970, s)
        }
    }

    public func suggestions() -> [TaskSuggestion] {
        let handled = handledThreads(), ruleList = rules()
        let quietThreads: Set<String> = ruleList.isEmpty ? [] : Set(emails(limit: 600).filter { m in ruleList.contains { $0.matches(m) } }.map(\.threadId))
        let stored: [TaskSuggestion] = (try? db.all("taskSuggestion", limit: 300, as: TaskSuggestion.self)) ?? []
        let known = Set(stored.map(\.id))
        let ai = stored.filter { s in
            guard !s.dismissed else { return false }
            if let t = s.threadId, handled.contains(t) || quietThreads.contains(t) { return false }
            return true
        }
        // With no AI key mail is never triaged, so suggest tasks from plain deadline wording instead.
        let tri = allTriage()
        let local: [TaskSuggestion] = emails(limit: 300).filter { m in
            tri[m.id] == nil && !known.contains("local." + m.id) && !handled.contains(m.threadId) && !quietThreads.contains(m.threadId) && m.isUnread && Self.looksActionable(m)
        }.prefix(6).map { m in
            TaskSuggestion(id: "local." + m.id, title: "Check: \(m.subject)", due: nil, priority: .medium, sourceDescription: "\(m.fromName): \(m.subject)", threadId: m.threadId, dismissed: false)
        }
        return ai + local
    }

    static let actionable = try! NSRegularExpression(pattern: #"(\bdue\b|deadline|expires?|expiring|overdue|action required|please (reply|confirm|sign|respond|review)|\bby (mon|tue|wed|thu|fri|sat|sun)|invoice|renewal|payment (failed|due)|final (notice|reminder))"#, options: .caseInsensitive)
    static func looksActionable(_ m: EmailMessage) -> Bool {
        let text = m.subject + " " + m.snippet
        return actionable.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }
    public func dismiss(_ s: TaskSuggestion) { var x = s; x.dismissed = true; try? db.put("taskSuggestion", id: s.id, sort: 0, x) }

    /// One summary for a whole bundle, cached until its set of conversations changes.
    public func bundleSummary(_ b: MailBundle, regenerate: Bool = false) async throws -> String {
        if !regenerate, let c: ThreadSummary = try? db.get("bundleSummary", id: b.id), c.messageCount == b.count { return c.text }
        let text = try await intel.summarizeBundle(title: b.title, messages: b.rows.map(\.message))
        try? db.put("bundleSummary", id: b.id, ThreadSummary(threadId: b.id, text: text, messageCount: b.count))
        return text
    }
    public func cachedBundleSummary(_ b: MailBundle) -> String? {
        guard let c: ThreadSummary = try? db.get("bundleSummary", id: b.id), c.messageCount == b.count else { return nil }
        return c.text
    }

    public func summary(for threadId: String, regenerate: Bool = false) async throws -> String {
        let msgs = thread(threadId)
        if !regenerate, let c: ThreadSummary = try? db.get("threadSummary", id: threadId), c.messageCount == msgs.count { return c.text }
        let text = try await intel.summarizeThread(msgs)
        try? db.put("threadSummary", id: threadId, ThreadSummary(threadId: threadId, text: text, messageCount: msgs.count))
        return text
    }

    public func cachedSummary(for threadId: String) -> String? {
        guard let c: ThreadSummary = try? db.get("threadSummary", id: threadId), c.messageCount == thread(threadId).count else { return nil }
        return c.text
    }

    public func draft(for threadId: String, tone: String, myName: String, guidance: String = "") async throws -> ReplyDraft {
        let text = try await intel.draftReply(thread: thread(threadId), tone: tone, myName: myName, guidance: guidance)
        let d = ReplyDraft(threadId: threadId, tone: tone, text: text)
        try? db.put("replyDraft", id: d.id, d)
        return d
    }

    // MARK: Write actions (each requires explicit approval)
    // The screen updates first. The mail server is told afterwards, and the change is put back if it fails.

    /// Removes a conversation from the local inbox immediately and returns what was removed.
    public func removeLocally(threadId: String) -> [EmailMessage] {
        let msgs = thread(threadId)
        for m in msgs { removeLocal(m.id) }
        return msgs
    }
    public func restore(_ msgs: [EmailMessage]) { for m in msgs { store(m) } }

    public func commitArchive(_ msgs: [EmailMessage], _ approval: UserApproval) async throws { try await backend.archive(msgs.filter(\.inInbox)) }
    public func commitTrash(_ msgs: [EmailMessage], _ approval: UserApproval) async throws { try await backend.trash(msgs) }

    /// Marks a conversation read locally and returns the unread messages it changed.
    public func setReadLocally(threadId: String) -> [EmailMessage] {
        let unread = thread(threadId).filter(\.isUnread)
        for m in unread { var x = m; x.labelIds.removeAll { $0 == "UNREAD" }; store(x) }
        return unread
    }
    public func commitMarkRead(_ msgs: [EmailMessage], _ approval: UserApproval) async throws { try await backend.markRead(msgs) }

    public func archive(threadId: String, _ approval: UserApproval) async throws {
        let msgs = removeLocally(threadId: threadId)
        do { try await commitArchive(msgs, approval) } catch { restore(msgs); throw error }
    }
    public func trash(threadId: String, _ approval: UserApproval) async throws {
        let msgs = removeLocally(threadId: threadId)
        do { try await commitTrash(msgs, approval) } catch { restore(msgs); throw error }
    }
    public func markRead(threadId: String, _ approval: UserApproval) async throws {
        let msgs = setReadLocally(threadId: threadId)
        do { try await commitMarkRead(msgs, approval) } catch { restore(msgs); throw error }
    }

    private func replyTarget(_ threadId: String) -> EmailMessage? {
        let t = thread(threadId)
        let me = (accountEmail ?? "").lowercased()
        return t.last(where: { $0.fromAddress.lowercased() != me }) ?? t.last
    }

    public func saveDraft(threadId: String, body: String, _ approval: UserApproval) async throws {
        guard let m = replyTarget(threadId) else { return }
        try await backend.saveDraft(replyingTo: m, body: body)
    }

    public func sendReply(threadId: String, body: String, _ approval: UserApproval) async throws {
        guard let m = replyTarget(threadId) else { return }
        try await backend.sendReply(replyingTo: m, body: body)
    }
}
