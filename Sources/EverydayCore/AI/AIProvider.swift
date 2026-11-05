import Foundation

public struct AIMessage: Sendable, Hashable {
    public enum Role: String, Sendable { case user, assistant }
    public var role: Role
    public var text: String
    public init(_ role: Role, _ text: String) { self.role = role; self.text = text }
}

public struct AIRequest: Sendable {
    public var system: String
    public var messages: [AIMessage]
    public var maxTokens: Int = 1024
    public var temperature: Double = 0.3
    public var json: Bool = false
    public init(system: String, messages: [AIMessage], maxTokens: Int = 1024, temperature: Double = 0.3, json: Bool = false) {
        self.system = system; self.messages = messages; self.maxTokens = maxTokens; self.temperature = temperature; self.json = json
    }
}

public struct AIResponse: Sendable {
    public var text: String
    public var inputTokens: Int
    public var outputTokens: Int
}

public enum AIError: Error, LocalizedError {
    case notConfigured(String)
    case http(Int, String)
    case badResponse(String)
    case budgetExceeded
    public var errorDescription: String? {
        switch self {
        case .notConfigured(let s): return s
        case .http(let c, let m): return "Provider returned \(c): \(m)"
        case .badResponse(let m): return "Unexpected response: \(m)"
        case .budgetExceeded: return "Monthly AI token cap reached. Raise it in Settings → AI provider."
        }
    }
}

public protocol AIProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    func complete(_ request: AIRequest, model: String) async throws -> AIResponse
    func stream(_ request: AIRequest, model: String) -> AsyncThrowingStream<String, Error>
    func listModels() async throws -> [String]
}

enum HTTP {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    /// Retries overload and rate-limit responses (429, 500, 502, 503, 504) with exponential backoff.
    static func send(_ req: URLRequest, attempts: Int = 4) async throws -> Data {
        var attempt = 0
        while true {
            let data: Data, resp: URLResponse
            do { (data, resp) = try await session.data(for: req) }
            catch let e as URLError where [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(e.code) {
                attempt += 1
                if attempt < min(attempts, 2) { try await Task.sleep(nanoseconds: 1_000_000_000); continue }
                throw AIError.badResponse("The provider did not respond in time. Check your connection and try again.")
            }
            guard let http = resp as? HTTPURLResponse else { throw AIError.badResponse("no HTTP response") }
            if (200..<300).contains(http.statusCode) { return data }
            attempt += 1
            let msg = errorMessage(from: data)
            if attempt < attempts {
                if [500, 502, 503, 504].contains(http.statusCode) {
                    try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 700_000_000)); continue
                }
                // 429: wait only when the provider says the wait is short (per-minute limits); daily/zero quotas fail fast.
                if http.statusCode == 429, let wait = retryDelay(msg), wait <= 20 {
                    try await Task.sleep(nanoseconds: UInt64((wait + 0.5) * 1_000_000_000)); continue
                }
            }
            throw AIError.http(http.statusCode, friendly(http.statusCode, msg))
        }
    }

    static func retryDelay(_ msg: String) -> Double? {
        guard let r = msg.range(of: #"retry in ([0-9]+(\.[0-9]+)?)s"#, options: .regularExpression) else { return nil }
        return Double(msg[r].replacingOccurrences(of: "retry in ", with: "").replacingOccurrences(of: "s", with: ""))
    }

    static func friendly(_ code: Int, _ msg: String) -> String {
        if code == 429, msg.contains("free_tier") || msg.contains("limit: 0") {
            return "This model has no free-tier quota on your key. Choose a Flash model in Settings → AI provider, or enable billing for the key."
        }
        if code == 403, msg.lowercased().contains("unregistered callers") { return "No valid API key was sent. Re-paste the key in Settings → AI provider." }
        if code == 503 || code == 429 { return "The provider is overloaded or rate-limited right now. Try again in a minute. (\(msg))" }
        return msg
    }

    static func errorMessage(from data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let e = obj["error"] as? [String: Any], let m = e["message"] as? String { return m }
            if let e = obj["error"] as? String { return e }
            if let m = obj["message"] as? String { return m }
        }
        return String(data: data.prefix(300), encoding: .utf8) ?? "unknown error"
    }

    /// Server-sent events: yields each `data:` payload.
    static func sse(_ req: URLRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    let (bytes, resp) = try await session.bytes(for: req)
                    guard let http = resp as? HTTPURLResponse else { throw AIError.badResponse("no HTTP response") }
                    if !(200..<300).contains(http.statusCode) {
                        var body = Data()
                        for try await b in bytes { body.append(b); if body.count > 2000 { break } }
                        throw AIError.http(http.statusCode, friendly(http.statusCode, errorMessage(from: body)))
                    }
                    for try await line in bytes.lines {
                        if line.hasPrefix("data:") {
                            let p = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            if p == "[DONE]" { break }
                            cont.yield(p)
                        }
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}

/// Pulls the first JSON object or array out of a model reply, tolerating code fences and prose.
public func extractJSON(_ text: String) -> Data? {
    var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("```") {
        s = s.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let startIdx = s.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
    let open = s[startIdx]
    let close: Character = open == "{" ? "}" : "]"
    guard let endIdx = s.lastIndex(of: close), endIdx > startIdx else { return nil }
    return String(s[startIdx...endIdx]).data(using: .utf8)
}
