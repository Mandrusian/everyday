import Foundation

public enum GmailError: Error, LocalizedError {
    case http(Int, String), parse(String)
    public var errorDescription: String? {
        switch self {
        case .http(let c, let m): return "Gmail returned \(c): \(m)"
        case .parse(let m): return "Could not read Gmail response: \(m)"
        }
    }
}

public struct HistoryChanges: Sendable { public var changedIDs: Set<String>; public var deletedIDs: Set<String>; public var historyId: String }

public final class GmailClient: @unchecked Sendable {
    private let auth: GoogleAuth
    private let base = "https://gmail.googleapis.com/gmail/v1/users/me"
    public init(auth: GoogleAuth) { self.auth = auth }

    private func request(_ path: String, method: String = "GET", query: [String: String] = [:], body: [String: Any]? = nil) async throws -> [String: Any] {
        var c = URLComponents(string: base + path)!
        if !query.isEmpty { c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: c.url!)
        req.httpMethod = method
        req.setValue("Bearer \(try await auth.accessToken())", forHTTPHeaderField: "Authorization")
        if let body { req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        var attempt = 0
        while true {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let msg = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any])?["message"] as? String ?? "request failed"
            if code == 429 || code >= 500, attempt < 3 { attempt += 1; try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 500_000_000)); continue }
            // Per-minute quota (new Google Cloud projects start low): wait it out rather than fail the sync.
            if code == 403, msg.lowercased().contains("quota") || msg.lowercased().contains("rate limit"), attempt < 6 {
                attempt += 1; try await Task.sleep(nanoseconds: UInt64(8_000_000_000 * attempt)); continue
            }
            guard (200..<300).contains(code) else { throw GmailError.http(code, msg) }
            if data.isEmpty { return [:] }
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
    }

    /// Downloads one attached file by name.
    public func attachment(messageId: String, name: String) async throws -> Data {
        let o = try await request("/messages/\(messageId)", query: ["format": "full"])
        func find(_ part: [String: Any]) -> String? {
            if (part["filename"] as? String) == name, let aid = (part["body"] as? [String: Any])?["attachmentId"] as? String { return aid }
            for p in (part["parts"] as? [[String: Any]]) ?? [] { if let a = find(p) { return a } }
            return nil
        }
        guard let payload = o["payload"] as? [String: Any], let aid = find(payload) else { throw GmailError.parse("attachment not found") }
        let a = try await request("/messages/\(messageId)/attachments/\(aid)")
        guard let data = a["data"] as? String, let d = Self.decodeB64URL(data) else { throw GmailError.parse("attachment had no data") }
        return d
    }

    public func profile() async throws -> (email: String, historyId: String) {
        let o = try await request("/profile")
        return (o["emailAddress"] as? String ?? "", String(describing: o["historyId"] ?? ""))
    }

    public func listIDs(query: String, max: Int) async throws -> [String] {
        var ids: [String] = []
        var token: String?
        repeat {
            var q = ["q": query, "maxResults": String(min(100, max - ids.count))]
            if let t = token { q["pageToken"] = t }
            let o = try await request("/messages", query: q)
            ids += (o["messages"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
            token = o["nextPageToken"] as? String
        } while token != nil && ids.count < max
        return ids
    }

    public func message(id: String) async throws -> EmailMessage {
        let o = try await request("/messages/\(id)", query: ["format": "full"])
        return try Self.parse(o)
    }

    public func history(since: String) async throws -> HistoryChanges? {
        var changed = Set<String>(), deleted = Set<String>()
        var latest = since
        var token: String?
        repeat {
            var q = ["startHistoryId": since, "historyTypes": "messageAdded", "maxResults": "500"]
            if let t = token { q["pageToken"] = t }
            let o: [String: Any]
            do { o = try await request("/history", query: q) }
            catch GmailError.http(404, _) { return nil }   // history expired: caller does a full resync
            for h in (o["history"] as? [[String: Any]]) ?? [] {
                for key in ["messagesAdded"] { for m in (h[key] as? [[String: Any]]) ?? [] { if let id = (m["message"] as? [String: Any])?["id"] as? String { changed.insert(id) } } }
            }
            if let hid = o["historyId"] { latest = String(describing: hid) }
            token = o["nextPageToken"] as? String
        } while token != nil
        // label changes and deletions need a second pass
        for type in ["labelAdded", "labelRemoved", "messageDeleted"] {
            var t2: String?
            repeat {
                var q = ["startHistoryId": since, "historyTypes": type, "maxResults": "500"]
                if let t = t2 { q["pageToken"] = t }
                let o = try await request("/history", query: q)
                for h in (o["history"] as? [[String: Any]]) ?? [] {
                    let key = type == "labelAdded" ? "labelsAdded" : type == "labelRemoved" ? "labelsRemoved" : "messagesDeleted"
                    for m in (h[key] as? [[String: Any]]) ?? [] {
                        if let id = (m["message"] as? [String: Any])?["id"] as? String { if type == "messageDeleted" { deleted.insert(id) } else { changed.insert(id) } }
                    }
                }
                t2 = o["nextPageToken"] as? String
            } while t2 != nil
        }
        return HistoryChanges(changedIDs: changed, deletedIDs: deleted, historyId: latest)
    }

    // MARK: Writes — only reachable through MailActions, which requires UserApproval.

    func modify(id: String, add: [String], remove: [String]) async throws {
        _ = try await request("/messages/\(id)/modify", method: "POST", body: ["addLabelIds": add, "removeLabelIds": remove])
    }
    func trash(id: String) async throws { _ = try await request("/messages/\(id)/trash", method: "POST") }
    func createDraft(raw: String, threadId: String?) async throws -> String {
        var m: [String: Any] = ["raw": raw]
        if let t = threadId { m["threadId"] = t }
        let o = try await request("/drafts", method: "POST", body: ["message": m])
        return o["id"] as? String ?? ""
    }
    func send(raw: String, threadId: String?) async throws {
        var b: [String: Any] = ["raw": raw]
        if let t = threadId { b["threadId"] = t }
        _ = try await request("/messages/send", method: "POST", body: b)
    }

    // MARK: Parsing

    static func decodeB64URL(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    public static func parse(_ o: [String: Any]) throws -> EmailMessage {
        guard let id = o["id"] as? String, let payload = o["payload"] as? [String: Any] else { throw GmailError.parse("missing payload") }
        let headers = (payload["headers"] as? [[String: Any]]) ?? []
        func h(_ n: String) -> String { headers.first { ($0["name"] as? String)?.lowercased() == n.lowercased() }?["value"] as? String ?? "" }
        var plain = "", html = "", attach = false, names: [String] = []
        func walk(_ part: [String: Any]) {
            let mime = (part["mimeType"] as? String) ?? ""
            if let fn = part["filename"] as? String, !fn.isEmpty { attach = true; names.append(fn) }
            if let body = part["body"] as? [String: Any], let data = body["data"] as? String, let d = decodeB64URL(data), let s = String(data: d, encoding: .utf8) {
                if mime == "text/plain" { plain += s } else if mime == "text/html" { html += s }
            }
            for p in (part["parts"] as? [[String: Any]]) ?? [] { walk(p) }
        }
        walk(payload)
        let body = plain.isEmpty ? HTMLText.plain(html) : plain
        let (name, addr) = parseAddress(h("From"))
        let ms = (o["internalDate"] as? String).flatMap(Double.init) ?? 0
        var msg = EmailMessage(id: id, threadId: o["threadId"] as? String ?? id, fromName: name, fromAddress: addr, to: h("To"), subject: HTMLText.decodeEntities(h("Subject")),
                            snippet: HTMLText.decodeEntities(o["snippet"] as? String ?? ""), body: body, date: Date(timeIntervalSince1970: ms / 1000),
                            labelIds: o["labelIds"] as? [String] ?? [], hasAttachments: attach, messageIdHeader: h("Message-ID"))
        msg.listUnsubscribe = h("List-Unsubscribe").isEmpty ? nil : h("List-Unsubscribe")
        msg.attachmentNames = names
        return msg
    }

    public static func parseAddress(_ s: String) -> (String, String) {
        if let l = s.lastIndex(of: "<"), let r = s.lastIndex(of: ">"), l < r {
            let addr = String(s[s.index(after: l)..<r])
            var name = String(s[..<l]).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if name.isEmpty { name = addr }
            return (name, addr)
        }
        return (s, s)
    }
}
