import Foundation

/// Gmail REST API backend (advanced option: the user brings their own Google OAuth client).
public final class GmailBackend: MailBackend, @unchecked Sendable {
    private let auth: GoogleAuth
    private let client: GmailClient
    public init(auth: GoogleAuth) { self.auth = auth; self.client = GmailClient(auth: auth) }

    public func attachmentData(_ message: EmailMessage, name: String) async throws -> Data { try await client.attachment(messageId: message.id, name: name) }

    public var isConnected: Bool { auth.accountEmail != nil }
    public var accountEmail: String? { auth.accountEmail }

    public func sync(days: Int, known: [EmailMessage], state: String?, progress: (@Sendable (String) -> Void)?) async throws -> SyncBatch {
        var ids: Set<String> = []
        var deleted: Set<String> = []
        let profile = try await client.profile()
        if let h = state, let changes = try await client.history(since: h) {
            ids = changes.changedIDs; deleted = changes.deletedIDs
        } else {
            progress?("Listing recent mail")
            ids = Set(try await client.listIDs(query: "in:inbox newer_than:\(days)d", max: 150))
        }
        let toFetch = Array(ids)
        var upserts: [EmailMessage] = []
        var removed = Array(deleted)
        var done = 0
        try await withThrowingTaskGroup(of: EmailMessage?.self) { group in
            var it = toFetch.makeIterator()
            var running = 0
            func add() -> Bool {
                guard let id = it.next() else { return false }
                group.addTask { [client] in
                    do { return try await client.message(id: id) } catch GmailError.http(404, _) { return nil }
                }
                return true
            }
            while running < 3, add() { running += 1 }
            for try await m in group {
                if let m { if m.inInbox { upserts.append(m) } else { removed.append(m.id) } }
                done += 1
                if done % 10 == 0 { progress?("Fetched \(done) of \(toFetch.count)") }
                _ = add()
            }
        }
        return SyncBatch(upserts: upserts, removedIDs: removed, state: profile.historyId)
    }

    public func archive(_ messages: [EmailMessage]) async throws { for m in messages where m.inInbox { try await client.modify(id: m.id, add: [], remove: ["INBOX"]) } }
    public func trash(_ messages: [EmailMessage]) async throws { for m in messages { try await client.trash(id: m.id) } }
    public func markRead(_ messages: [EmailMessage]) async throws { for m in messages where m.isUnread { try await client.modify(id: m.id, add: [], remove: ["UNREAD"]) } }

    private func raw(replyingTo m: EmailMessage, body: String) throws -> String {
        guard let me = accountEmail else { throw GoogleAuthError.cancelled }
        let to = MailComposer.replyRecipient(m, me: me)
        let data = MailComposer.build(from: me, to: to, subject: MailComposer.replySubject(m.subject), body: body, inReplyTo: m.messageIdHeader, domain: me.split(separator: "@").last.map(String.init) ?? "gmail.com")
        return data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public func saveDraft(replyingTo m: EmailMessage, body: String) async throws { _ = try await client.createDraft(raw: try raw(replyingTo: m, body: body), threadId: m.threadId) }
    public func sendReply(replyingTo m: EmailMessage, body: String) async throws { try await client.send(raw: try raw(replyingTo: m, body: body), threadId: m.threadId) }

    public func signOut() { auth.signOut() }
}
