import CryptoKit
import Foundation

/// Wi‑Fi sync between a person's own devices, the same protocol as the Rust core (windows/core/src/sync.rs).
/// Devices in one sync group share a 32-byte key, given once by QR code or pairing code. Frames are a 4-byte
/// big-endian length, then nonce + ChaCha20-Poly1305 ciphertext + tag (CryptoKit's `combined` layout).
/// Records merge last-writer-wins on (time, device); deletions are kept so they spread.
public enum SyncJSON: Codable, Equatable, Sendable {
    case null, bool(Bool), int(Int64), double(Double), string(String), array([SyncJSON]), object([String: SyncJSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int64.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([SyncJSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: SyncJSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
    public subscript(_ k: String) -> SyncJSON { if case .object(let o) = self { return o[k] ?? .null }; return .null }
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var int: Int64? { switch self { case .int(let i): return i; case .double(let d): return Int64(d); default: return nil } }
    public static func opt(_ s: String?) -> SyncJSON { s.map { .string($0) } ?? .null }
    public static func opt(_ d: Date?) -> SyncJSON { d.map { .int(Int64($0.timeIntervalSince1970)) } ?? .null }
}

public struct SyncRecord: Codable, Equatable, Sendable {
    public var v: SyncJSON
    public var t: Int64
    public var d: String
    public var del: Bool

    enum CodingKeys: String, CodingKey { case v, t, d, del }
    public init(v: SyncJSON, t: Int64, d: String, del: Bool = false) { self.v = v; self.t = t; self.d = d; self.del = del }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decodeIfPresent(SyncJSON.self, forKey: .v) ?? .null
        t = try c.decode(Int64.self, forKey: .t); d = try c.decode(String.self, forKey: .d)
        del = try c.decodeIfPresent(Bool.self, forKey: .del) ?? false
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v); try c.encode(t, forKey: .t); try c.encode(d, forKey: .d)
        if del { try c.encode(true, forKey: .del) }
    }
    func newer(than o: SyncRecord) -> Bool { t != o.t ? t > o.t : d > o.d }
}

public struct SyncState: Codable, Equatable, Sendable {
    public var records: [String: SyncRecord] = [:]
    public init() {}
    public mutating func set(_ key: String, _ v: SyncJSON, now: Int64, device: String) { records[key] = SyncRecord(v: v, t: now, d: device) }
    public mutating func delete(_ key: String, now: Int64, device: String) { records[key] = SyncRecord(v: .null, t: now, d: device, del: true) }
    /// Returns the keys that changed here.
    @discardableResult public mutating func merge(_ other: SyncState) -> [String] {
        var changed: [String] = []
        for (k, r) in other.records where records[k].map({ r.newer(than: $0) }) ?? true { records[k] = r; changed.append(k) }
        return changed.sorted()
    }
    public func live(_ kind: String) -> [(id: String, value: SyncJSON)] {
        records.filter { !$0.value.del && $0.key.hasPrefix(kind + ":") }.map { (String($0.key.dropFirst(kind.count + 1)), $0.value.v) }.sorted { $0.id < $1.id }
    }
}

public struct SyncHello: Codable, Sendable {
    public var device: String; public var name: String; public var state: SyncState
    /// Sent by a newly paired device: the one-time token from the pairing code, asking for the setup bundle.
    public var setupToken: String? = nil
    /// The setup bundle, in reply to a valid token.
    public var setup: SyncJSON? = nil
    public init(device: String, name: String, state: SyncState, setupToken: String? = nil, setup: SyncJSON? = nil) { self.device = device; self.name = name; self.state = state; self.setupToken = setupToken; self.setup = setup }
}

public enum SyncError: Error, LocalizedError {
    case notPaired, badCode, io(String), format(String)
    public var errorDescription: String? {
        switch self {
        case .notPaired: "The other device isn't paired with this one."
        case .badCode: "That isn't an everyday. pairing code."
        case .io(let e): "Couldn't reach the other device: \(e)"
        case .format(let e): "The other device sent something unexpected: \(e)"
        }
    }
}

public struct SyncGroup: Sendable {
    public let key: SymmetricKey
    public init() { key = SymmetricKey(size: .bits256) }
    public init?(keyBase64 s: String) {
        guard let d = Data(base64URL: s), d.count == 32 else { return nil }
        key = SymmetricKey(data: d)
    }
    /// "everyday-sync:1:<key>" or "everyday-sync:1:<key>:<setup token>".
    public init?(pairingURI s: String) {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("everyday-sync:1:") else { return nil }
        self.init(keyBase64: String(t.dropFirst("everyday-sync:1:".count).split(separator: ":").first ?? ""))
    }
    public static func setupToken(in s: String) -> String? {
        let parts = s.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        return parts.count >= 4 ? String(parts[3]) : nil
    }
    public var keyBase64: String { key.withUnsafeBytes { Data($0) }.base64URL }
    public var pairingURI: String { "everyday-sync:1:\(keyBase64)" }
    /// Public id advertised on the network so devices only talk to their own group.
    public var id: String {
        let raw = key.withUnsafeBytes { Data($0) }
        return SHA256.hash(data: Data("everyday-sync-group".utf8) + raw).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
    public func seal(_ plain: Data) throws -> Data { try ChaChaPoly.seal(plain, using: key).combined }
    public func open(_ sealed: Data) throws -> Data {
        guard sealed.count >= 28, let box = try? ChaChaPoly.SealedBox(combined: sealed), let d = try? ChaChaPoly.open(box, using: key) else { throw SyncError.notPaired }
        return d
    }
}

public enum SyncKeys {
    /// Same as the Rust `mail_key`: sender plus subject without reply prefixes, so a conversation matches across devices whose mail ids differ.
    public static func mailKey(from: String, subject: String) -> String {
        var s = subject.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while let p = ["re:", "fwd:", "fw:"].first(where: { s.hasPrefix($0) }) { s = String(s.dropFirst(p.count)).trimmingCharacters(in: .whitespaces) }
        s = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let f = from.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return SHA256.hash(data: Data("\(f)|\(s)".utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
    public static func newDeviceID() -> String { (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined() }
}

extension Data {
    public init?(base64URL s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        self.init(base64Encoded: b)
    }
    public var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}

// MARK: - Local data <-> records

/// Maps the Mac's tasks, news topics, handled mail and saved stories to sync records and back.
public final class SyncData: @unchecked Sendable {
    let db: Database, tasks: TaskStore, mail: MailService, prefs: Prefs
    public init(db: Database, tasks: TaskStore, mail: MailService, prefs: Prefs) { self.db = db; self.tasks = tasks; self.mail = mail; self.prefs = prefs }

    public var deviceID: String {
        let id = prefs.string("sync.device")
        if !id.isEmpty { return id }
        let n = SyncKeys.newDeviceID(); prefs.set(n, "sync.device"); return n
    }
    public var deviceName: String { let n = prefs.string("sync.name"); return n.isEmpty ? (Host.current().localizedName ?? "Mac") : n }

    func load() -> SyncState { (try? db.get("sync", id: "state", as: SyncState.self)) ?? SyncState() }
    func save(_ s: SyncState) { try? db.put("sync", id: "state", s) }

    static let priorities = ["low", "medium", "high"]

    func export() -> [String: SyncJSON] {
        var m: [String: SyncJSON] = [:]
        for t in tasks.all() {
            m["task:\(t.id)"] = .object(["title": .string(t.title), "notes": .string(t.notes), "due": .opt(t.due), "done": .opt(t.completedAt),
                                         "priority": .string(Self.priorities[t.priority.rawValue]), "created": .opt(t.createdAt), "repeats": .opt(t.repeats?.rawValue)])
        }
        for c in prefs.strings(Prefs.Key.categories) { m["topic:\(c)"] = .bool(true) }
        let handled = mail.handledThreadIDs()
        for e in mail.emails(limit: 5000, inboxOnly: false) where handled.contains(e.threadId) { m["handled:\(SyncKeys.mailKey(from: e.fromAddress, subject: e.subject))"] = .bool(true) }
        return m
    }

    /// Stamps what changed since the last sync. Handled flags aren't removed this way (their mail may not be here yet).
    public func prepare(now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> SyncState {
        var s = load(); let me = deviceID; let local = export()
        for (k, v) in local where !(s.records[k].map { !$0.del && $0.v == v } ?? false) { s.set(k, v, now: now, device: me) }
        for (k, r) in s.records where !r.del && (k.hasPrefix("task:") || k.hasPrefix("topic:")) && local[k] == nil { s.delete(k, now: now, device: me) }
        apply(s, keys: s.records.keys.filter { $0.hasPrefix("handled:") })
        save(s); return s
    }

    /// Writes changed records into local data. Returns whether anything visible changed.
    @discardableResult public func apply(_ s: SyncState, keys: [String]) -> Bool {
        var topics = false, any = false
        var handled: [(String, Bool)] = []
        for k in keys {
            guard let r = s.records[k], let colon = k.firstIndex(of: ":") else { continue }
            let kind = String(k[..<colon]), id = String(k[k.index(after: colon)...])
            switch kind {
            case "task":
                any = true
                if r.del { if let t = tasks.all().first(where: { $0.id == id }) { tasks.delete(t) }; continue }
                let v = r.v
                var t = tasks.all().first(where: { $0.id == id }) ?? TaskItem(id: id, title: "")
                t.title = v["title"].string ?? ""; t.notes = v["notes"].string ?? ""
                t.due = v["due"].int.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                t.completedAt = v["done"].int.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                t.priority = TaskPriority(rawValue: Self.priorities.firstIndex(of: v["priority"].string ?? "medium") ?? 1) ?? .medium
                if let c = v["created"].int { t.createdAt = Date(timeIntervalSince1970: TimeInterval(c)) }
                t.repeats = v["repeats"].string.flatMap(TaskRepeat.init(rawValue:))
                tasks.save(t)
            case "topic": topics = true
            case "handled": handled.append((id, !r.del))
            default: break
            }
        }
        if topics { prefs.set(s.live("topic").map(\.id), Prefs.Key.categories); any = true }
        if !handled.isEmpty {
            let mails = mail.emails(limit: 5000, inboxOnly: false), on = mail.handledThreadIDs()
            for (key, flag) in handled {
                for e in mails where SyncKeys.mailKey(from: e.fromAddress, subject: e.subject) == key && on.contains(e.threadId) != flag {
                    if flag { mail.markHandled(threadId: e.threadId) } else { mail.unhandle(threadId: e.threadId) }
                    any = true
                }
            }
        }
        return any
    }

    public func finish(_ s: SyncState, changed: [String]) -> Bool { let any = apply(s, keys: changed); save(s); return any }
}
