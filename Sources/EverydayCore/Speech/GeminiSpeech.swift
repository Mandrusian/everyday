import Foundation
import CryptoKit

/// Natural text to speech from Gemini's speech models, using the user's own key.
/// The text is sent to Google (and shown in the AI activity log). Audio is cached on disk so replays are free and instant.
public final class GeminiSpeech: @unchecked Sendable {
    public struct Voice: Identifiable, Hashable, Sendable { public var id: String; public var trait: String; public var male: Bool; public var title: String { "\(id) · \(trait)" } }

    public static let voices: [Voice] = [
        Voice(id: "Charon", trait: "Informative", male: true), Voice(id: "Achird", trait: "Friendly", male: true), Voice(id: "Iapetus", trait: "Clear", male: true),
        Voice(id: "Orus", trait: "Firm", male: true), Voice(id: "Schedar", trait: "Even", male: true), Voice(id: "Sadaltager", trait: "Knowledgeable", male: true),
        Voice(id: "Rasalgethi", trait: "Informative", male: true), Voice(id: "Umbriel", trait: "Easy-going", male: true), Voice(id: "Zubenelgenubi", trait: "Casual", male: true),
        Voice(id: "Alnilam", trait: "Firm", male: true), Voice(id: "Puck", trait: "Upbeat", male: true), Voice(id: "Enceladus", trait: "Breathy", male: true),
        Voice(id: "Algenib", trait: "Gravelly", male: true), Voice(id: "Fenrir", trait: "Excitable", male: true), Voice(id: "Sadachbia", trait: "Lively", male: true),
        Voice(id: "Kore", trait: "Firm", male: false), Voice(id: "Zephyr", trait: "Bright", male: false), Voice(id: "Leda", trait: "Youthful", male: false),
        Voice(id: "Aoede", trait: "Breezy", male: false), Voice(id: "Sulafat", trait: "Warm", male: false), Voice(id: "Gacrux", trait: "Mature", male: false),
        Voice(id: "Vindemiatrix", trait: "Gentle", male: false), Voice(id: "Achernar", trait: "Soft", male: false), Voice(id: "Despina", trait: "Smooth", male: false),
    ]
    /// Direction text is read aloud by the speech models (measured: 3.3 s plain vs 16 s with a long direction), so none is sent.
    public static let defaultStyle = ""

    private let apiKey: String
    private let session: URLSession
    public let cacheDir: URL
    public init(apiKey: String, cacheDir: URL? = nil) {
        self.apiKey = apiKey
        let c = URLSessionConfiguration.default; c.timeoutIntervalForRequest = 90
        session = URLSession(configuration: c)
        self.cacheDir = cacheDir ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("everyday/tts", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.cacheDir, withIntermediateDirectories: true)
    }

    /// Speech-capable models the key can use, newest full model first, Lite after.
    public func models() async -> [String] {
        var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=200")!)
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        guard let (data, _) = try? await session.data(for: req), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let ms = obj["models"] as? [[String: Any]] else { return [] }
        let names = ms.compactMap { ($0["name"] as? String)?.replacingOccurrences(of: "models/", with: "") }.filter { $0.hasPrefix("gemini") && $0.contains("tts") }
        func version(_ n: String) -> Double { n.range(of: #"gemini-([0-9]+(?:\.[0-9]+)?)"#, options: .regularExpression).flatMap { Double(n[$0].dropFirst(7)) } ?? 0 }
        func rank(_ n: String) -> (Int, Double) { (n.contains("lite") ? 1 : (n.contains("preview") ? 0 : 0), -version(n)) }
        return names.sorted { rank($0) < rank($1) }
    }

    public func key(model: String, voice: String, style: String, text: String) -> String {
        SHA256.hash(data: Data("\(model)|\(voice)|\(style)|\(text)".utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    public enum SpeechError: Error, LocalizedError {
        case noModel, http(Int, String), noAudio
        public var errorDescription: String? {
            switch self {
            case .noModel: return "No Gemini speech model is available for this key."
            case .http(let c, let m): return "Gemini speech returned \(c): \(m)"
            case .noAudio: return "Gemini returned no audio."
            }
        }
    }

    /// Returns WAV data for the text. Tries each model in turn; remembers the one that worked.
    public func audio(for text: String, voice: String, style: String = defaultStyle, models: [String]) async throws -> (wav: Data, model: String) {
        guard !models.isEmpty else { throw SpeechError.noModel }
        var lastError: Error = SpeechError.noModel
        for m in models.prefix(4) {
            let file = cacheDir.appendingPathComponent(key(model: m, voice: voice, style: style, text: text) + ".wav")
            if let d = try? Data(contentsOf: file) { return (d, m) }
            do {
                let wav = try await synthesize(text, voice: voice, style: style, model: m)
                try? wav.write(to: file, options: .atomic)
                return (wav, m)
            } catch SpeechError.http(let code, let msg) where [400, 404, 429, 500, 502, 503, 504].contains(code) {
                lastError = SpeechError.http(code, msg); continue
            }
        }
        throw lastError
    }

    func synthesize(_ text: String, voice: String, style: String, model: String) async throws -> Data {
        var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "contents": [["parts": [["text": style.isEmpty ? text : "\(style) \(text)"]]]],
            "generationConfig": ["responseModalities": ["AUDIO"], "speechConfig": ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": voice]]]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        var attempt = 0
        while true {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(code) { return try Self.wavFromResponse(data) }
            attempt += 1
            if [500, 502, 503, 504].contains(code), attempt < 3 { try await Task.sleep(nanoseconds: 800_000_000); continue }
            throw SpeechError.http(code, HTTP.errorMessage(from: data))
        }
    }

    static func wavFromResponse(_ data: Data) throws -> Data {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let cand = (o["candidates"] as? [[String: Any]])?.first,
              let parts = (cand["content"] as? [String: Any])?["parts"] as? [[String: Any]],
              let inline = parts.compactMap({ $0["inlineData"] as? [String: Any] }).first, let b64 = inline["data"] as? String, let pcm = Data(base64Encoded: b64), !pcm.isEmpty
        else { throw SpeechError.noAudio }
        var rate = 24000
        if let mime = inline["mimeType"] as? String, let r = mime.range(of: #"rate=(\d+)"#, options: .regularExpression) { rate = Int(mime[r].dropFirst(5)) ?? 24000 }
        return wav(pcm16: pcm, sampleRate: rate)
    }

    /// 16-bit mono PCM → WAV file bytes.
    public static func wav(pcm16 pcm: Data, sampleRate: Int) -> Data {
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(36 + pcm.count); d.append("WAVEfmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(pcm.count); d.append(pcm)
        return d
    }

    public func clearCache() { try? FileManager.default.removeItem(at: cacheDir); try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true) }
    public func cacheSize() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}
