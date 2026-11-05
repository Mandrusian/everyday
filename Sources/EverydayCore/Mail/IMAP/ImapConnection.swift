import Foundation
import Network

public enum ImapError: Error, LocalizedError {
    case connect(String), auth(String), command(String, String), timeout, closed, unsupported(String)
    public var errorDescription: String? {
        switch self {
        case .connect(let m): return "Could not connect to the mail server: \(m)"
        case .auth(let m): return "The server refused the sign-in. \(m)"
        case .command(let c, let m): return "Mail server error on \(c): \(m)"
        case .timeout: return "The mail server did not answer in time."
        case .closed: return "The mail server closed the connection."
        case .unsupported(let m): return m
        }
    }
}

/// One line of an untagged response. Literals ({n} blocks) are pulled out and the marker replaced by U+0001.
struct ImapLine { var text: String; var literals: [Data] }

struct ImapResult {
    var status: String        // OK, NO, BAD
    var text: String          // remainder of the tagged line
    var untagged: [ImapLine]
}

/// Minimal IMAP4rev1 client over TLS (Network.framework). Calls must be made one at a time.
final class ImapConnection: @unchecked Sendable {
    private let conn: NWConnection
    private var buffer = Data()
    private var tagCounter = 0
    private let queue = DispatchQueue(label: "everyday.imap")
    private var timedOut = false
    let host: String

    init(host: String, port: UInt16, tls: Bool = true) {
        self.host = host
        let params: NWParameters = tls ? .tls : .tcp
        conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 993, using: params)
    }

    func open(timeout: TimeInterval = 20) async throws {
        final class Once: @unchecked Sendable { let l = NSLock(); var done = false; func take() -> Bool { l.lock(); defer { l.unlock() }; if done { return false }; done = true; return true } }
        let once = Once()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { [conn] state in
                switch state {
                case .ready: if once.take() { cont.resume() }
                case .failed(let e): if once.take() { cont.resume(throwing: ImapError.connect(e.localizedDescription)) }
                case .waiting(let e): if once.take() { conn.cancel(); cont.resume(throwing: ImapError.connect(e.localizedDescription)) }
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [conn] in if once.take() { conn.cancel(); cont.resume(throwing: ImapError.timeout) } }
        }
        let greeting = try await readLine()
        guard let g = String(data: greeting, encoding: .utf8), g.hasPrefix("* OK") || g.hasPrefix("* PREAUTH") else {
            throw ImapError.connect("unexpected greeting")
        }
    }

    func close() { conn.cancel() }

    private func fill() async throws {
        let data: Data = try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let error { cont.resume(throwing: error) }
                else if let data, !data.isEmpty { cont.resume(returning: data) }
                else if isComplete { cont.resume(throwing: ImapError.closed) }
                else { cont.resume(returning: Data()) }
            }
        }
        buffer.append(data)
    }

    /// Next line without its CRLF.
    func readLine() async throws -> Data {
        while true {
            if let r = buffer.range(of: Data([13, 10])) {
                let line = buffer.subdata(in: buffer.startIndex..<r.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<r.upperBound)
                return line
            }
            try await fill()
        }
    }

    func readExactly(_ n: Int) async throws -> Data {
        while buffer.count < n { try await fill() }
        let d = buffer.prefix(n)
        buffer.removeFirst(n)
        return Data(d)
    }

    func write(_ s: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: Data(s.utf8), completion: .contentProcessed { e in if let e { cont.resume(throwing: e) } else { cont.resume() } })
        }
    }

    /// Sends one tagged command and collects the response. Throws on NO/BAD unless `allowFailure`.
    @discardableResult
    func run(_ command: String, timeout: TimeInterval = 90, allowFailure: Bool = false, literalAfterContinuation: Data? = nil) async throws -> ImapResult {
        tagCounter += 1
        let tag = "A\(tagCounter)"
        timedOut = false
        let watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if !Task.isCancelled { self?.timedOut = true; self?.conn.cancel() }
        }
        defer { watchdog.cancel() }
        do {
            try await write("\(tag) \(command)\r\n")
            var untagged: [ImapLine] = []
            while true {
                let raw = try await readLine()
                var text = String(decoding: raw, as: UTF8.self)
                if text.hasPrefix("+"), let lit = literalAfterContinuation {   // APPEND continuation
                    try await write(String(decoding: lit, as: UTF8.self) + "\r\n")
                    continue
                }
                if text.hasPrefix("\(tag) ") {
                    let rest = text.dropFirst(tag.count + 1)
                    let parts = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                    let status = parts.first.map(String.init)?.uppercased() ?? "BAD"
                    let tail = parts.count > 1 ? String(parts[1]) : ""
                    if status != "OK" && !allowFailure {
                        let name = String(command.split(separator: " ").first ?? "")
                        throw name.uppercased() == "LOGIN" || name.uppercased() == "AUTHENTICATE" ? ImapError.auth(tail) : ImapError.command(name, tail)
                    }
                    return ImapResult(status: status, text: tail, untagged: untagged)
                }
                var literals: [Data] = []
                while let m = text.range(of: #"\{(\d+)\}$"#, options: .regularExpression) {
                    let n = Int(text[m].dropFirst().dropLast()) ?? 0
                    literals.append(try await readExactly(n))
                    text.replaceSubrange(m, with: "\u{1}")
                    text += String(decoding: try await readLine(), as: UTF8.self)
                }
                untagged.append(ImapLine(text: text, literals: literals))
            }
        } catch {
            if timedOut { throw ImapError.timeout }
            throw error
        }
    }

    // MARK: Helpers

    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    func login(user: String, password: String) async throws {
        guard user.allSatisfy(\.isASCII), password.allSatisfy(\.isASCII) else { throw ImapError.auth("Use an ASCII app password.") }
        try await run("LOGIN \(Self.quote(user)) \(Self.quote(password))")
    }
}
