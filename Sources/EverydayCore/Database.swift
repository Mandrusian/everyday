import Foundation
import SQLite3

public enum SQLValue: Sendable {
    case null, int(Int64), double(Double), text(String)
    public var string: String? { if case .text(let s) = self { return s }; return nil }
    public var int64: Int64? { if case .int(let i) = self { return i }; return nil }
    public var double: Double? { switch self { case .double(let d): return d; case .int(let i): return Double(i); default: return nil } }
}

public struct DBError: Error, LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

/// Minimal serialised SQLite wrapper. Everything is local, in Application Support.
public final class Database: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "everyday.db")
    public let url: URL?

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("everyday", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent(ProcessInfo.processInfo.environment["EVERYDAY_DEV"] == "1" ? "everyday-dev.sqlite" : "everyday.sqlite")
    }

    /// Pass nil for an in-memory database (used by checks).
    public init(url: URL?) throws {
        self.url = url
        let path = url?.path ?? ":memory:"
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            throw DBError(message: "Cannot open database at \(path)")
        }
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA foreign_keys=ON;")
        try migrate()
    }

    deinit { sqlite3_close(db) }

    private func migrate() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS docs(
            kind TEXT NOT NULL, id TEXT NOT NULL, sort REAL NOT NULL DEFAULT 0, json TEXT NOT NULL,
            PRIMARY KEY(kind, id)
        );
        CREATE INDEX IF NOT EXISTS docs_sort ON docs(kind, sort DESC);
        CREATE INDEX IF NOT EXISTS docs_email_thread ON docs(json_extract(json, '$.threadId')) WHERE kind = 'email';
        CREATE VIRTUAL TABLE IF NOT EXISTS mail_fts USING fts5(id UNINDEXED, subject, sender, body, tokenize='porter unicode61');
        """)
    }

    @discardableResult
    public func exec(_ sql: String, _ params: [SQLValue] = []) throws -> Int {
        try queue.sync {
            if params.isEmpty {
                var err: UnsafeMutablePointer<CChar>?
                if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
                    let m = err.map { String(cString: $0) } ?? "sqlite error"
                    sqlite3_free(err)
                    throw DBError(message: m)
                }
                return Int(sqlite3_changes(db))
            }
            let stmt = try prepare(sql, params)
            defer { sqlite3_finalize(stmt) }
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw DBError(message: String(cString: sqlite3_errmsg(db))) }
            return Int(sqlite3_changes(db))
        }
    }

    public func query(_ sql: String, _ params: [SQLValue] = []) throws -> [[String: SQLValue]] {
        try queue.sync {
            let stmt = try prepare(sql, params)
            defer { sqlite3_finalize(stmt) }
            var rows: [[String: SQLValue]] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw DBError(message: String(cString: sqlite3_errmsg(db))) }
                var row: [String: SQLValue] = [:]
                for i in 0..<sqlite3_column_count(stmt) {
                    let name = String(cString: sqlite3_column_name(stmt, i))
                    switch sqlite3_column_type(stmt, i) {
                    case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(stmt, i))
                    case SQLITE_FLOAT: row[name] = .double(sqlite3_column_double(stmt, i))
                    case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(stmt, i)))
                    default: row[name] = .null
                    }
                }
                rows.append(row)
            }
            return rows
        }
    }

    private func prepare(_ sql: String, _ params: [SQLValue]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError(message: String(cString: sqlite3_errmsg(db)))
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .null: sqlite3_bind_null(stmt, idx)
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, transient)
            }
        }
        return stmt
    }

    // MARK: Document helpers

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    public func put<T: Encodable>(_ kind: String, id: String, sort: Double = 0, _ value: T) throws {
        let data = try Self.encoder.encode(value)
        let json = String(decoding: data, as: UTF8.self)
        try exec("INSERT INTO docs(kind,id,sort,json) VALUES(?,?,?,?) ON CONFLICT(kind,id) DO UPDATE SET sort=excluded.sort, json=excluded.json",
                 [.text(kind), .text(id), .double(sort), .text(json)])
    }

    public func get<T: Decodable>(_ kind: String, id: String, as type: T.Type = T.self) throws -> T? {
        let rows = try query("SELECT json FROM docs WHERE kind=? AND id=?", [.text(kind), .text(id)])
        guard let json = rows.first?["json"]?.string else { return nil }
        return try Self.decoder.decode(T.self, from: Data(json.utf8))
    }

    public func all<T: Decodable>(_ kind: String, limit: Int = 5000, as type: T.Type = T.self) throws -> [T] {
        let rows = try query("SELECT json FROM docs WHERE kind=? ORDER BY sort DESC LIMIT ?", [.text(kind), .int(Int64(limit))])
        return try rows.compactMap { r in
            guard let j = r["json"]?.string else { return nil }
            return try Self.decoder.decode(T.self, from: Data(j.utf8))
        }
    }

    /// Documents of one kind whose top-level JSON string field equals a value, without decoding the whole table.
    public func allWhere<T: Decodable>(_ kind: String, field: String, equals value: String, as type: T.Type = T.self) throws -> [T] {
        precondition(field.allSatisfy { $0.isLetter || $0.isNumber }, "field must be a plain name")
        let rows = try query("SELECT json FROM docs WHERE kind=? AND json_extract(json, '$.\(field)')=?", [.text(kind), .text(value)])
        return try rows.compactMap { r in
            guard let j = r["json"]?.string else { return nil }
            return try Self.decoder.decode(T.self, from: Data(j.utf8))
        }
    }

    public func delete(_ kind: String, id: String) throws {
        try exec("DELETE FROM docs WHERE kind=? AND id=?", [.text(kind), .text(id)])
    }

    public func deleteAll(_ kind: String) throws {
        try exec("DELETE FROM docs WHERE kind=?", [.text(kind)])
    }

    public func count(_ kind: String) throws -> Int {
        Int(try query("SELECT COUNT(*) AS c FROM docs WHERE kind=?", [.text(kind)]).first?["c"]?.int64 ?? 0)
    }

    public func wipeEverything() throws {
        try exec("DELETE FROM docs; DELETE FROM mail_fts;")
    }

    // MARK: Mail full-text search

    public func indexMail(id: String, subject: String, sender: String, body: String) throws {
        try exec("DELETE FROM mail_fts WHERE id=?", [.text(id)])
        try exec("INSERT INTO mail_fts(id,subject,sender,body) VALUES(?,?,?,?)", [.text(id), .text(subject), .text(sender), .text(body)])
    }

    public func searchMail(_ text: String, limit: Int = 50) throws -> [String] {
        let tokens = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { "\($0)*" }
        guard !tokens.isEmpty else { return [] }
        let q = tokens.joined(separator: " ")
        return try query("SELECT id FROM mail_fts WHERE mail_fts MATCH ? ORDER BY rank LIMIT ?", [.text(q), .int(Int64(limit))])
            .compactMap { $0["id"]?.string }
    }
}
