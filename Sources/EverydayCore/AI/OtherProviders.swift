import Foundation

public struct AnthropicProvider: AIProvider {
    public let id = "anthropic"
    public let displayName = "Anthropic"
    let apiKey: String
    public init(apiKey: String) { self.apiKey = apiKey }

    private func request(_ r: AIRequest, model: String, stream: Bool) throws -> URLRequest {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        var b: [String: Any] = [
            "model": model, "max_tokens": r.maxTokens, "temperature": r.temperature, "stream": stream,
            "messages": r.messages.map { ["role": $0.role.rawValue, "content": $0.text] },
        ]
        if !r.system.isEmpty { b["system"] = r.system + (r.json ? "\nReply with a single JSON value and nothing else." : "") }
        req.httpBody = try JSONSerialization.data(withJSONObject: b)
        return req
    }

    public func complete(_ r: AIRequest, model: String) async throws -> AIResponse {
        let data = try await HTTP.send(try request(r, model: model, stream: false))
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [[String: Any]] else { throw AIError.badResponse("no content") }
        let text = content.compactMap { $0["text"] as? String }.joined()
        let usage = obj["usage"] as? [String: Any]
        return AIResponse(text: text, inputTokens: usage?["input_tokens"] as? Int ?? 0, outputTokens: usage?["output_tokens"] as? Int ?? 0)
    }

    public func stream(_ r: AIRequest, model: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    for try await p in HTTP.sse(try request(r, model: model, stream: true)) {
                        guard let d = p.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                              o["type"] as? String == "content_block_delta",
                              let delta = o["delta"] as? [String: Any], let t = delta["text"] as? String else { continue }
                        cont.yield(t)
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    public func listModels() async throws -> [String] {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=100")!)
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let data = try await HTTP.send(req)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
    }
}

/// OpenAI, and any OpenAI-compatible server (Ollama, LM Studio) via a custom endpoint.
public struct OpenAICompatProvider: AIProvider {
    public let id: String
    public let displayName: String
    let apiKey: String
    let endpoint: String   // e.g. https://api.openai.com/v1 or http://localhost:11434/v1
    public init(id: String, displayName: String, apiKey: String, endpoint: String) {
        self.id = id; self.displayName = displayName; self.apiKey = apiKey; self.endpoint = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
    }

    private func request(_ r: AIRequest, model: String, stream: Bool) throws -> URLRequest {
        guard let url = URL(string: "\(endpoint)/chat/completions") else { throw AIError.notConfigured("Invalid endpoint") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization") }
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        var msgs: [[String: String]] = []
        if !r.system.isEmpty { msgs.append(["role": "system", "content": r.system]) }
        msgs += r.messages.map { ["role": $0.role.rawValue, "content": $0.text] }
        var b: [String: Any] = ["model": model, "messages": msgs, "temperature": r.temperature, "stream": stream, "max_tokens": r.maxTokens]
        if r.json { b["response_format"] = ["type": "json_object"] }
        req.httpBody = try JSONSerialization.data(withJSONObject: b)
        return req
    }

    public func complete(_ r: AIRequest, model: String) async throws -> AIResponse {
        let data = try await HTTP.send(try request(r, model: model, stream: false))
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any], let text = msg["content"] as? String else { throw AIError.badResponse("no choices") }
        let usage = obj["usage"] as? [String: Any]
        return AIResponse(text: text, inputTokens: usage?["prompt_tokens"] as? Int ?? 0, outputTokens: usage?["completion_tokens"] as? Int ?? 0)
    }

    public func stream(_ r: AIRequest, model: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    for try await p in HTTP.sse(try request(r, model: model, stream: true)) {
                        guard let d = p.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                              let ch = (o["choices"] as? [[String: Any]])?.first, let delta = ch["delta"] as? [String: Any],
                              let t = delta["content"] as? String else { continue }
                        cont.yield(t)
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    public func listModels() async throws -> [String] {
        guard let url = URL(string: "\(endpoint)/models") else { return [] }
        var req = URLRequest(url: url)
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization") }
        let data = try await HTTP.send(req)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ((obj?["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []).sorted()
    }
}
