import Foundation

public final class ImapBackend: MailBackend, @unchecked Sendable {
    private let prefs: Prefs
    private let testing: (host: String, port: UInt16, tls: Bool)?     // local fake server in checks
    /// The account this backend works with. Nil means the first account in the list.
    public let boundEmail: String?
    public init(prefs: Prefs = .shared, testing: (host: String, port: UInt16, tls: Bool)? = nil, email: String? = nil) {
        self.prefs = prefs; self.testing = testing; self.boundEmail = email
    }
    /// The same setup, working with another of the reader's accounts.
    public func bound(to email: String) -> ImapBackend { ImapBackend(prefs: prefs, testing: testing, email: email) }

    // MARK: Account storage

    public var account: ImapAccount? {
        let list = ImapAccounts.load(prefs)
        guard let e = boundEmail?.lowercased() else { return list.first }
        return list.first { $0.email.lowercased() == e }
    }
    public static func passwordKey(_ email: String) -> String { "imap.password.\(email.lowercased())" }
    /// Saves the account (adding it to the list, or updating it if the address is already there) and its password.
    public func save(account: ImapAccount, password: String) throws {
        let cleaned = password.components(separatedBy: .whitespacesAndNewlines).joined()
        try Keychain.set(cleaned, for: Self.passwordKey(account.email))
        ImapAccounts.upsert(account, prefs)
    }
    public func remove() {
        guard let a = account else { return }
        Keychain.delete(Self.passwordKey(a.email))
        ImapAccounts.remove(email: a.email, prefs)
    }
    var password: String { account.flatMap { Keychain.get(Self.passwordKey($0.email)) } ?? "" }

    public var isConnected: Bool { account != nil && !password.isEmpty }
    public var accountEmail: String? { account?.email }

    /// Used by the setup wizard before anything is saved.
    public static func test(account: ImapAccount, password: String) async throws -> Int {
        let b = ImapBackend(prefs: Prefs(suite: "everyday.imap.test"))
        return try await b.session(account: account, password: password) { c in
            let r = try await c.run("SELECT INBOX")
            return r.untagged.compactMap { l -> Int? in
                guard let m = l.text.range(of: #"^\* (\d+) EXISTS"#, options: .regularExpression) else { return nil }
                return Int(l.text[m].split(separator: " ")[1])
            }.first ?? 0
        }
    }

    // MARK: Session

    private func session<T>(account: ImapAccount? = nil, password: String? = nil, _ body: (ImapConnection) async throws -> T) async throws -> T {
        guard let acct = account ?? self.account else { throw ImapError.unsupported("No mail account is set up.") }
        let c = testing.map { ImapConnection(host: $0.host, port: $0.port, tls: $0.tls) }
            ?? ImapConnection(host: acct.imapHost, port: UInt16(acct.imapPort))
        try await c.open()
        defer { c.close() }
        try await c.login(user: acct.username, password: password ?? self.password)
        return try await body(c)
    }

    struct Selected { var validity: Int; var uidNext: Int }

    private func select(_ c: ImapConnection) async throws -> Selected {
        let r = try await c.run("SELECT INBOX")
        var v = 0, n = 0
        for l in r.untagged {
            if let m = l.text.range(of: #"UIDVALIDITY (\d+)"#, options: .regularExpression) { v = Int(l.text[m].split(separator: " ")[1]) ?? 0 }
            if let m = l.text.range(of: #"UIDNEXT (\d+)"#, options: .regularExpression) { n = Int(l.text[m].split(separator: " ")[1]) ?? 0 }
        }
        return Selected(validity: v, uidNext: n)
    }

    // MARK: Ids

    /// Ids are "imap:validity:uid" for the first account and "imap:tag:validity:uid" for any added later, so two accounts never collide.
    static func makeID(validity: Int, uid: Int, tag: String? = nil) -> String { tag.map { "imap:\($0):\(validity):\(uid)" } ?? "imap:\(validity):\(uid)" }
    public static func parseID(_ id: String) -> (validity: Int, uid: Int)? {
        let p = id.split(separator: ":")
        guard p.first == "imap", p.count == 3 || p.count == 4, let v = Int(p[p.count - 2]), let u = Int(p[p.count - 1]) else { return nil }
        return (v, u)
    }

    // MARK: Parsing FETCH

    struct Fetched { var uid: Int; var flags: Set<String>; var internalDate: Date?; var body: Data? }

    static func parseFetch(_ lines: [ImapLine]) -> [Fetched] {
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "dd-MMM-yyyy HH:mm:ss Z"
        return lines.compactMap { l -> Fetched? in
            guard l.text.contains(" FETCH ("), let um = l.text.range(of: #"UID (\d+)"#, options: .regularExpression),
                  let uid = Int(l.text[um].dropFirst(4)) else { return nil }
            var flags = Set<String>()
            if let fm = l.text.range(of: #"FLAGS \(([^)]*)\)"#, options: .regularExpression) {
                let inner = l.text[fm].dropFirst(7).dropLast()
                flags = Set(inner.split(separator: " ").map { $0.lowercased() })
            }
            var date: Date?
            if let dm = l.text.range(of: #"INTERNALDATE "([^"]+)""#, options: .regularExpression) {
                date = df.date(from: String(l.text[dm].dropFirst(13).dropLast()))
            }
            return Fetched(uid: uid, flags: flags, internalDate: date, body: l.literals.first)
        }
    }

    func message(from f: Fetched, validity: Int) -> EmailMessage {
        let p = MIME.parse(f.body ?? Data())
        let body = p.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let snippet = String(body.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).prefix(160))
        var labels = ["INBOX"]
        if !f.flags.contains("\\seen") { labels.append("UNREAD") }
        var msg = EmailMessage(id: Self.makeID(validity: validity, uid: f.uid, tag: account?.tag), threadId: "t" + Hashing.short(p.threadKey), fromName: p.fromName.isEmpty ? p.fromAddress : p.fromName,
                            fromAddress: p.fromAddress, to: p.to, subject: p.subject.isEmpty ? "(no subject)" : p.subject, snippet: snippet, body: body,
                            date: p.date ?? f.internalDate ?? Date(), labelIds: labels, hasAttachments: p.hasAttachments, messageIdHeader: p.messageId)
        msg.listUnsubscribe = p.listUnsubscribe
        msg.attachmentNames = p.attachmentNames
        msg.account = account?.email
        return msg
    }

    // MARK: Sync

    public func sync(days: Int, known: [EmailMessage], state: String?, progress: (@Sendable (String) -> Void)?) async throws -> SyncBatch {
        try await session { c in
            progress?("Connected")
            let sel = try await select(c)
            var lastUID = 0
            if let st = state?.split(separator: ":"), st.count == 2, Int(st[0]) == sel.validity { lastUID = Int(st[1]) ?? 0 }
            let mine = known.filter { Self.parseID($0.id)?.validity == sel.validity }
            var removed: [String] = known.filter { Self.parseID($0.id)?.validity != sel.validity }.map(\.id)   // UIDVALIDITY changed: old ids are void
            var upserts: [EmailMessage] = []

            // New messages
            var uids: [Int]
            if lastUID == 0 {
                let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "dd-MMM-yyyy"
                let since = df.string(from: Date().addingTimeInterval(-Double(days) * 86400))
                let r = try await c.run("UID SEARCH SINCE \(since)")
                uids = Self.searchIDs(r)
                uids = Array(uids.sorted(by: >).prefix(150))
            } else {
                let r = try await c.run("UID SEARCH UID \(lastUID + 1):*")
                uids = Self.searchIDs(r).filter { $0 > lastUID }
            }
            var maxUID = lastUID
            let chunks = stride(from: 0, to: uids.count, by: 8).map { Array(uids[$0..<min($0 + 8, uids.count)]) }
            var done = 0
            for chunk in chunks {
                let set = chunk.map(String.init).joined(separator: ",")
                let r = try await c.run("UID FETCH \(set) (UID FLAGS INTERNALDATE BODY.PEEK[]<0.400000>)", timeout: 120)
                for f in Self.parseFetch(r.untagged) { upserts.append(message(from: f, validity: sel.validity)); maxUID = max(maxUID, f.uid) }
                done += chunk.count
                progress?("Fetched \(done) of \(uids.count)")
            }

            // Flag changes and removals for what we already hold
            if let minUID = mine.compactMap({ Self.parseID($0.id)?.uid }).min() {
                let r = try await c.run("UID FETCH \(minUID):* (UID FLAGS)", timeout: 120)
                var seen: [Int: Set<String>] = [:]
                for f in Self.parseFetch(r.untagged) { seen[f.uid] = f.flags }
                for m in mine {
                    guard let uid = Self.parseID(m.id)?.uid else { continue }
                    guard let flags = seen[uid] else { removed.append(m.id); continue }
                    let nowUnread = !flags.contains("\\seen")
                    if nowUnread != m.isUnread {
                        var x = m
                        x.labelIds.removeAll { $0 == "UNREAD" }
                        if nowUnread { x.labelIds.append("UNREAD") }
                        upserts.append(x)
                    }
                }
            }
            return SyncBatch(upserts: upserts, removedIDs: removed, state: "\(sel.validity):\(maxUID)")
        }
    }

    static func searchIDs(_ r: ImapResult) -> [Int] {
        r.untagged.filter { $0.text.hasPrefix("* SEARCH") }.flatMap { $0.text.dropFirst(8).split(separator: " ").compactMap { Int($0) } }
    }

    // MARK: Folders

    struct Folders { var trash: String?; var archive: String?; var drafts: String?; var sent: String?; var canMove: Bool }

    private func folders(_ c: ImapConnection) async throws -> Folders {
        let cap = try await c.run("CAPABILITY")
        let canMove = cap.untagged.contains { $0.text.uppercased().contains(" MOVE") }
        let list = try await c.run(#"LIST "" "*""#)
        var found: [(flags: Set<String>, name: String)] = []
        for l in list.untagged where l.text.hasPrefix("* LIST") {
            guard let fm = l.text.range(of: #"\(([^)]*)\)"#, options: .regularExpression) else { continue }
            let flags = Set(l.text[fm].dropFirst().dropLast().split(separator: " ").map { $0.lowercased() })
            var rest = String(l.text[fm.upperBound...]).trimmingCharacters(in: .whitespaces)
            // skip hierarchy delimiter
            if rest.hasPrefix("\"") { rest = String(rest.dropFirst(rest.dropFirst().firstIndex(of: "\"").map { rest.distance(from: rest.startIndex, to: $0) + 2 } ?? 1)) }
            else if rest.uppercased().hasPrefix("NIL") { rest = String(rest.dropFirst(3)) }
            rest = rest.trimmingCharacters(in: .whitespaces)
            var name = rest
            if name == "\u{1}", let lit = l.literals.last { name = String(decoding: lit, as: UTF8.self) }
            if name.hasPrefix("\"") && name.hasSuffix("\"") && name.count >= 2 { name = String(name.dropFirst().dropLast()) }
            found.append((flags, name))
        }
        func pick(_ flag: String, _ names: [String]) -> String? {
            found.first { $0.flags.contains(flag) }?.name ?? found.first { f in names.contains { f.name.lowercased().hasSuffix($0) } }?.name
        }
        return Folders(trash: pick("\\trash", ["trash", "deleted items", "deleted messages"]),
                       archive: pick("\\archive", ["archive"]) ?? pick("\\all", ["all mail"]),
                       drafts: pick("\\drafts", ["drafts"]), sent: pick("\\sent", ["sent", "sent mail", "sent items"]), canMove: canMove)
    }

    private func uids(_ msgs: [EmailMessage], validity: Int) -> [Int] { msgs.compactMap { Self.parseID($0.id) }.filter { $0.validity == validity }.map(\.uid) }

    private func moveOut(_ messages: [EmailMessage], to pick: (Folders) -> String?, what: String) async throws {
        try await session { c in
            let sel = try await select(c)
            let ids = uids(messages, validity: sel.validity)
            guard !ids.isEmpty else { return }
            let f = try await folders(c)
            guard let dest = pick(f) else { throw ImapError.unsupported("This account has no \(what) folder to move mail into.") }
            let set = ids.map(String.init).joined(separator: ",")
            if f.canMove { try await c.run("UID MOVE \(set) \(ImapConnection.quote(dest))") }
            else {
                try await c.run("UID COPY \(set) \(ImapConnection.quote(dest))")
                try await c.run("UID STORE \(set) +FLAGS.SILENT (\\Deleted)")
                if (try? await c.run("UID EXPUNGE \(set)", allowFailure: true).status) != "OK" { try await c.run("EXPUNGE") }
            }
        }
    }

    public func archive(_ messages: [EmailMessage]) async throws { try await moveOut(messages, to: \.archive, what: "archive") }
    public func trash(_ messages: [EmailMessage]) async throws { try await moveOut(messages, to: \.trash, what: "trash") }

    public func attachmentData(_ m: EmailMessage, name: String) async throws -> Data {
        guard let id = Self.parseID(m.id) else { throw ImapError.unsupported("This message can't be located on the server.") }
        return try await session { c in
            let sel = try await select(c)
            guard sel.validity == id.validity else { throw ImapError.unsupported("The mailbox was rebuilt. Sync again, then retry.") }
            let r = try await c.run("UID FETCH \(id.uid) (UID BODY.PEEK[])", timeout: 180)
            guard let raw = Self.parseFetch(r.untagged).first?.body else { throw ImapError.unsupported("The server did not return the message.") }
            guard let d = MIME.attachments(in: raw, includeData: true).first(where: { $0.info.name == name })?.data else { throw ImapError.unsupported("That attachment was not found in the message.") }
            return d
        }
    }

    public func markRead(_ messages: [EmailMessage]) async throws {
        try await session { c in
            let sel = try await select(c)
            let ids = uids(messages, validity: sel.validity)
            guard !ids.isEmpty else { return }
            try await c.run("UID STORE \(ids.map(String.init).joined(separator: ",")) +FLAGS.SILENT (\\Seen)")
        }
    }

    // MARK: Compose

    private func compose(replyingTo m: EmailMessage, body: String) throws -> (data: Data, to: String, from: String) {
        guard let a = account else { throw ImapError.unsupported("No mail account is set up.") }
        let to = MailComposer.replyRecipient(m, me: a.email)
        let data = MailComposer.build(from: a.email, to: to, subject: MailComposer.replySubject(m.subject), body: body, inReplyTo: m.messageIdHeader, domain: a.email.split(separator: "@").last.map(String.init) ?? "localhost")
        return (data, to, a.email)
    }

    private func append(_ data: Data, flag: String, pick: (Folders) -> String?) async throws {
        try await session { c in
            let f = try await folders(c)
            guard let name = pick(f) else { throw ImapError.unsupported("This account has no matching folder.") }
            let text = String(decoding: data, as: UTF8.self)
            try await c.run("APPEND \(ImapConnection.quote(name)) (\(flag)) {\(data.count)}", literalAfterContinuation: Data(text.utf8))
        }
    }

    public func saveDraft(replyingTo m: EmailMessage, body: String) async throws {
        let c = try compose(replyingTo: m, body: body)
        try await append(c.data, flag: "\\Draft", pick: \.drafts)
    }

    public func sendReply(replyingTo m: EmailMessage, body: String) async throws {
        guard let a = account else { throw ImapError.unsupported("No mail account is set up.") }
        let c = try compose(replyingTo: m, body: body)
        try await SmtpSender.send(account: a, password: password, from: c.from, to: [SmtpSender.bareAddress(c.to)], message: c.data)
        if a.presetID != "gmail" { try? await append(c.data, flag: "\\Seen", pick: \.sent) }   // Gmail files sent mail itself
    }
}
