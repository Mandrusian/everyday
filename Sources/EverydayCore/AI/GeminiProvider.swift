import Foundation

public struct GeminiProvider: AIProvider {
    public let id = "gemini"
    public let displayName = "Gemini"
    let apiKey: String
    static let base = "https://generativelanguage.googleapis.com/v1beta"
    public init(apiKey: String) { self.apiKey = apiKey }

    private func body(_ r: AIRequest) -> [String: Any] {
        // Newer Gemini models spend part of the output budget on hidden "thinking", so leave generous headroom or replies truncate.
        var gen: [String: Any] = ["maxOutputTokens": r.maxTokens + 3072, "temperature": r.temperature]
        if r.json { gen["responseMimeType"] = "application/json" }
        var b: [String: Any] = [
            "contents": r.messages.map { ["role": $0.role == .user ? "user" : "model", "parts": [["text": $0.text]]] },
            "generationConfig": gen,
        ]
        if !r.system.isEmpty { b["systemInstruction"] = ["parts": [["text": r.system]]] }
        return b
    }

    private func request(_ path: String, model: String, _ r: AIRequest) throws -> URLRequest {
        guard let url = URL(string: "\(Self.base)/models/\(model):\(path)") else { throw AIError.notConfigured("Invalid model name") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body(r))
        return req
    }

    static func text(from obj: [String: Any]) -> String {
        guard let cands = obj["candidates"] as? [[String: Any]],
              let content = cands.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return "" }
        return parts.compactMap { $0["text"] as? String }.joined()
    }

    public func complete(_ r: AIRequest, model: String) async throws -> AIResponse {
        let data = try await HTTP.send(try request("generateContent", model: model, r))
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIError.badResponse("not JSON") }
        let text = Self.text(from: obj)
        if text.isEmpty {
            let reason = ((obj["candidates"] as? [[String: Any]])?.first?["finishReason"] as? String)
                ?? ((obj["promptFeedback"] as? [String: Any])?["blockReason"] as? String) ?? "empty reply"
            throw AIError.badResponse("Gemini returned no text (\(reason))")
        }
        let usage = obj["usageMetadata"] as? [String: Any]
        return AIResponse(text: text, inputTokens: usage?["promptTokenCount"] as? Int ?? 0, outputTokens: usage?["candidatesTokenCount"] as? Int ?? 0)
    }

    public func stream(_ r: AIRequest, model: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    var req = try request("streamGenerateContent?alt=sse", model: model, r)
                    if let u = req.url, let fixed = URL(string: u.absoluteString.replacingOccurrences(of: "%3F", with: "?")) { req.url = fixed }
                    for try await payload in HTTP.sse(req) {
                        if let d = payload.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                            let t = Self.text(from: obj)
                            if !t.isEmpty { cont.yield(t) }
                        }
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    public func listModels() async throws -> [String] {
        var req = URLRequest(url: URL(string: "\(Self.base)/models?pageSize=200")!)
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let data = try await HTTP.send(req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any], let models = obj["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { m -> String? in
            guard let name = m["name"] as? String,
                  let methods = m["supportedGenerationMethods"] as? [String], methods.contains("generateContent") else { return nil }
            return name.replacingOccurrences(of: "models/", with: "")
        }.filter { n in n.hasPrefix("gemini") && !["image", "tts", "computer-use", "embedding", "live", "audio", "robotics", "native", "thinking-exp", "learnlm", "aqa"].contains(where: n.contains) }.sorted()
    }
}
