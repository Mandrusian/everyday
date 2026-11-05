import Foundation

public struct AIActivity: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var date: Date
    public var provider: String
    public var model: String
    public var job: String
    public var label: String
    public var payload: String
    public var inputTokens: Int
    public var outputTokens: Int
}

public enum AIJob: String, Sendable, CaseIterable {
    case triage, summary, chat
    public var title: String { switch self { case .triage: "Sorting mail and news"; case .summary: "Summaries and replies"; case .chat: "Assistant chat" } }
}

public enum ProviderID: String, CaseIterable, Sendable, Identifiable {
    case gemini, anthropic, openai, local, apple
    public var id: String { rawValue }
    public var title: String {
        switch self { case .gemini: "Gemini"; case .anthropic: "Anthropic"; case .openai: "OpenAI"; case .local: "Local (Ollama)"; case .apple: "Apple on-device" }
    }
    public var needsKey: Bool { self == .gemini || self == .anthropic || self == .openai }
    public func defaultModel(_ job: AIJob) -> String {
        switch self {
        case .gemini: return "gemini-flash-latest"
        case .anthropic: return job == .triage ? "claude-haiku-5-5" : "claude-sonnet-5-5"
        case .openai: return job == .triage ? "gpt-4o-mini" : "gpt-4o"
        case .local: return "llama3.2"
        case .apple: return "system"
        }
    }
}

/// Single entry point for every AI call. Applies the token budget, records an auditable log of
/// exactly what was sent, and never has access to mail write operations.
public final class AIService: @unchecked Sendable {
    private let db: Database
    private let prefs: Prefs
    public init(db: Database, prefs: Prefs = .shared) { self.db = db; self.prefs = prefs }

    public var providerID: ProviderID {
        get { ProviderID(rawValue: prefs.string(Prefs.Key.provider, default: "gemini")) ?? .gemini }
        set { prefs.set(newValue.rawValue, Prefs.Key.provider) }
    }

    public func model(for job: AIJob, provider: ProviderID? = nil) -> String {
        let p = provider ?? providerID
        let key: String
        switch job { case .triage: key = Prefs.Key.triageModel; case .summary: key = Prefs.Key.summaryModel; case .chat: key = Prefs.Key.chatModel }
        let stored = prefs.string("\(key).\(p.rawValue)")
        if !stored.isEmpty { return stored }
        if p == .gemini, let first = discovered.first { return first }
        return p.defaultModel(job)
    }

    func storedModel(_ job: AIJob) -> String? {
        let key: String
        switch job { case .triage: key = Prefs.Key.triageModel; case .summary: key = Prefs.Key.summaryModel; case .chat: key = Prefs.Key.chatModel }
        let v = prefs.string("\(key).\(providerID.rawValue)")
        return v.isEmpty ? nil : v
    }

    public func setModel(_ m: String, for job: AIJob, provider: ProviderID? = nil) {
        let p = provider ?? providerID
        let key: String
        switch job { case .triage: key = Prefs.Key.triageModel; case .summary: key = Prefs.Key.summaryModel; case .chat: key = Prefs.Key.chatModel }
        prefs.set(m, "\(key).\(p.rawValue)")
    }

    public var localEndpoint: String {
        get { prefs.string(Prefs.Key.localEndpoint, default: "http://localhost:11434/v1") }
        set { prefs.set(newValue, Prefs.Key.localEndpoint) }
    }

    public func apiKey(for p: ProviderID) -> String? { Keychain.get(KeychainAccount.aiKey(p.rawValue)) }
    public func setAPIKey(_ key: String, for p: ProviderID) throws {
        let k = key.components(separatedBy: .whitespacesAndNewlines).joined()
        if k.isEmpty { Keychain.delete(KeychainAccount.aiKey(p.rawValue)); return }
        guard k.count >= 16, k.count <= 300 else {
            throw AIError.notConfigured("That does not look like an API key (\(k.count) characters). Copy just the key from your provider's dashboard.")
        }
        try Keychain.set(k, for: KeychainAccount.aiKey(p.rawValue))
    }

    public var isConfigured: Bool {
        switch providerID {
        case .gemini, .anthropic, .openai: return !(apiKey(for: providerID) ?? "").isEmpty
        case .local: return true
        case .apple: return AppleOnDevice.isAvailable
        }
    }

    public func makeProvider(_ id: ProviderID? = nil) throws -> AIProvider {
        let p = id ?? providerID
        switch p {
        case .gemini, .anthropic, .openai:
            guard let key = apiKey(for: p), !key.isEmpty else { throw AIError.notConfigured("Add your \(p.title) API key in Settings → AI provider.") }
            switch p {
            case .gemini: return GeminiProvider(apiKey: key)
            case .anthropic: return AnthropicProvider(apiKey: key)
            default: return OpenAICompatProvider(id: "openai", displayName: "OpenAI", apiKey: key, endpoint: "https://api.openai.com/v1")
            }
        case .local:
            return OpenAICompatProvider(id: "local", displayName: "Local", apiKey: "", endpoint: localEndpoint)
        case .apple:
            guard AppleOnDevice.isAvailable else { throw AIError.notConfigured("Apple Intelligence is not available on this Mac.") }
            return AppleOnDevice.provider()
        }
    }

    // MARK: Gemini model discovery
    // Google retires model names often, so the default is whatever the key's own model list says is newest.

    private let discoveryLock = NSLock()
    private var discoveredModels: [String] = []
    private var discoveredAt: Date = .distantPast
    var discovered: [String] { discoveryLock.withLock { discoveredModels } }

    /// Stable Flash models, newest first (full Flash before Flash-Lite), then the `-latest` alias.
    func geminiCandidates() async -> [String] {
        if discoveryLock.withLock({ Date().timeIntervalSince(discoveredAt) < 6 * 3600 && !discoveredModels.isEmpty }) { return discovered }
        guard let p = try? makeProvider(.gemini), let all = try? await p.listModels(), !all.isEmpty else { return discovered }
        func version(_ n: String) -> Double {
            guard let r = n.range(of: #"^gemini-([0-9]+(\.[0-9]+)?)-flash"#, options: .regularExpression) else { return 0 }
            let m = n[r].replacingOccurrences(of: "gemini-", with: "").replacingOccurrences(of: "-flash", with: "")
            return Double(m) ?? 0
        }
        let full = all.filter { $0.range(of: #"^gemini-[0-9]+(\.[0-9]+)?-flash$"#, options: .regularExpression) != nil }.sorted { version($0) > version($1) }
        let lite = all.filter { $0.range(of: #"^gemini-[0-9]+(\.[0-9]+)?-flash-lite$"#, options: .regularExpression) != nil }.sorted { version($0) > version($1) }
        let alias = all.contains("gemini-flash-latest") ? ["gemini-flash-latest"] : []
        let list = full + lite + alias
        guard !list.isEmpty else { return discovered }
        discoveryLock.withLock { discoveredModels = list; discoveredAt = Date() }
        return list
    }

    private var deadModels = Set<String>()          // 404: retired for this key
    private var cooldown: [String: Date] = [:]          // 429/5xx: skip for a minute

    private func usable(_ m: String) -> Bool {
        discoveryLock.withLock { !deadModels.contains(m) && (cooldown[m].map { $0 < Date() } ?? true) }
    }
    private func mark(_ m: String, _ error: Error) {
        guard case AIError.http(let code, _) = error else { return }
        discoveryLock.withLock {
            if code == 404 { deadModels.insert(m) }
            else if [429, 500, 502, 503, 504].contains(code) { cooldown[m] = Date().addingTimeInterval(code == 429 ? 90 : 20) }
        }
    }

    /// Models to try, in order. A model chosen in Settings goes first; other providers have no fallbacks.
    /// For Gemini: two newest full Flash models, then the two newest Flash-Lite (their quotas are far more generous), then the rest.
    private func attemptOrder(_ job: AIJob) async -> [String] {
        var order: [String] = []
        if let s = storedModel(job) { order.append(s) }
        if providerID == .gemini {
            var found = await geminiCandidates()
            if found.isEmpty { try? await Task.sleep(nanoseconds: 1_000_000_000); found = await geminiCandidates() }
            if found.isEmpty { found = ["gemini-3.8-flash", "gemini-3.5-flash-lite", "gemini-flash-latest"] }
            let lite = found.filter { $0.contains("lite") }, full = found.filter { !$0.contains("lite") }
            order += Array(full.prefix(2)) + Array(lite.prefix(2)) + Array(full.dropFirst(2)) + Array(lite.dropFirst(2))
        }
        if order.isEmpty { order = [providerID.defaultModel(job)] }
        var seen = Set<String>()
        let all = order.filter { seen.insert($0).inserted }
        let live = all.filter(usable)
        return live.isEmpty ? all : live
    }

    /// The most useful error to show: quota and overload explain more than "not found".
    private func bestError(_ errors: [Error]) -> Error {
        errors.last(where: { if case AIError.http(let c, _) = $0 { return c == 429 }; return false })
            ?? errors.last(where: { if case AIError.http(let c, _) = $0 { return c != 404 }; return false })
            ?? errors.last ?? AIError.notConfigured("No model available.")
    }

    private func isTimeout(_ e: Error) -> Bool {
        if case AIError.badResponse(let m) = e { return m.contains("did not respond in time") }
        return false
    }

    private func shouldTryNext(_ e: Error) -> Bool {
        if case AIError.http(let code, _) = e { return [404, 429, 500, 502, 503, 504].contains(code) }
        return false
    }

    // MARK: Speech

    /// Natural speech needs a Gemini key. Returns nil when it is not set up.
    public func speechClient() -> GeminiSpeech? {
        guard let key = apiKey(for: .gemini), !key.isEmpty else { return nil }
        return GeminiSpeech(apiKey: key)
    }

    /// Adds a text-to-speech request to the activity log so it is as visible as any other AI call.
    public func recordSpeech(model: String, text: String) {
        let a = AIActivity(id: UUID().uuidString, date: Date(), provider: "gemini", model: model, job: "speech", label: "Text to speech", payload: String(text.prefix(4000)), inputTokens: text.count / 4, outputTokens: 0)
        try? db.put("aiLog", id: a.id, sort: a.date.timeIntervalSince1970, a)
    }

    // MARK: Budget

    public var monthlyTokenCap: Double {   // in millions of tokens
        get { prefs.double(Prefs.Key.budgetUSD, default: 5) }
        set { prefs.set(newValue, Prefs.Key.budgetUSD) }
    }

    public func tokensUsedThisMonth() -> Int {
        let start = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
        let logs: [AIActivity] = (try? db.all("aiLog", limit: 20000)) ?? []
        return logs.filter { $0.date >= start }.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }
    }

    private func checkBudget() throws {
        let cap = monthlyTokenCap
        if cap > 0 && Double(tokensUsedThisMonth()) >= cap * 1_000_000 { throw AIError.budgetExceeded }
    }

    public func activityLog(limit: Int = 200) -> [AIActivity] { (try? db.all("aiLog", limit: limit)) ?? [] }
    public func clearLog() { try? db.deleteAll("aiLog") }

    private func record(provider: String, model: String, job: AIJob, label: String, request: AIRequest, response: AIResponse) {
        let payload = (request.system.isEmpty ? "" : "SYSTEM:\n\(request.system)\n\n") + request.messages.map { "\($0.role.rawValue.uppercased()):\n\($0.text)" }.joined(separator: "\n\n")
        let a = AIActivity(id: UUID().uuidString, date: Date(), provider: provider, model: model, job: job.rawValue, label: label, payload: payload, inputTokens: response.inputTokens, outputTokens: response.outputTokens)
        try? db.put("aiLog", id: a.id, sort: a.date.timeIntervalSince1970, a)
    }

    // MARK: Calls

    public func complete(_ job: AIJob, label: String, _ request: AIRequest) async throws -> String {
        try checkBudget()
        let provider = try makeProvider()
        var errors: [Error] = []
        let order = Array(await attemptOrder(job).prefix(8))
        for (i, m) in order.enumerated() {
            do {
                let resp = try await provider.complete(request, model: m)
                record(provider: provider.id, model: m, job: job, label: label, request: request, response: resp)
                return resp.text
            } catch {
                errors.append(error); mark(m, error)
                if i < order.count - 1, shouldTryNext(error) || isTimeout(error) { continue }
                throw bestError(errors)
            }
        }
        throw bestError(errors)
    }

    public func stream(_ job: AIJob, label: String, _ request: AIRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    try checkBudget()
                    let provider = try makeProvider()
                    var errors: [Error] = []
                    let order = Array(await attemptOrder(job).prefix(8))
                    for (i, m) in order.enumerated() {
                        var full = ""
                        do {
                            for try await chunk in provider.stream(request, model: m) { full += chunk; cont.yield(chunk) }
                            let est = AIResponse(text: full, inputTokens: (request.system.count + request.messages.reduce(0) { $0 + $1.text.count }) / 4, outputTokens: full.count / 4)
                            record(provider: provider.id, model: m, job: job, label: label, request: request, response: est)
                            cont.finish(); return
                        } catch {
                            errors.append(error); mark(m, error)
                            if full.isEmpty, i < order.count - 1, shouldTryNext(error) || isTimeout(error) { continue }
                            throw bestError(errors)
                        }
                    }
                    throw bestError(errors)
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// Lists models for the active provider (used by the model pickers).
    public func availableModels() async -> [String] {
        guard let p = try? makeProvider() else { return [] }
        return (try? await p.listModels()) ?? []
    }

    public func testConnection() async throws -> String {
        let r = AIRequest(system: "", messages: [AIMessage(.user, "Reply with the single word: ready")], maxTokens: 16, temperature: 0)
        return try await complete(.triage, label: "Connection test", r).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: Apple on-device model

#if canImport(FoundationModels)
import FoundationModels
#endif

public enum AppleOnDevice {
    public static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return SystemLanguageModel.default.availability == .available }
        #endif
        return false
    }
    static func provider() -> AIProvider { AppleProvider() }
}

struct AppleProvider: AIProvider {
    let id = "apple"
    let displayName = "Apple on-device"
    func complete(_ request: AIRequest, model: String) async throws -> AIResponse {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let session = LanguageModelSession(instructions: request.system)
            let prompt = request.messages.map { "\($0.role == .user ? "User" : "Assistant"): \($0.text)" }.joined(separator: "\n")
            let r = try await session.respond(to: prompt)
            return AIResponse(text: r.content, inputTokens: prompt.count / 4, outputTokens: r.content.count / 4)
        }
        #endif
        throw AIError.notConfigured("Apple Intelligence is not available on this Mac.")
    }
    func stream(_ request: AIRequest, model: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            Task {
                do { let r = try await complete(request, model: model); cont.yield(r.text); cont.finish() } catch { cont.finish(throwing: error) }
            }
        }
    }
    func listModels() async throws -> [String] { ["system"] }
}
