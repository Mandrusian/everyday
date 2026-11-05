import SwiftUI
import AVFoundation
import EverydayCore

/// Text to speech. Two engines: natural speech from Gemini (default when a Gemini key is set) and the best voice installed
/// on this Mac (offline fallback). Reads in chunks so the reader can highlight where it is.
@MainActor @Observable
final class SpeechService: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    static let shared = SpeechService()
    private let synth = AVSpeechSynthesizer()
    private var indexByUtterance: [ObjectIdentifier: Int] = [:]
    private var remaining = 0
    private var player: AVAudioPlayer?
    private var playbackDone: CheckedContinuation<Void, Never>?
    private var cloudTask: Task<Void, Never>?
    private var ttsModels: [String] = []
    var ai: AIService?                 // set at launch so natural speech can use the user's Gemini key

    var owner: String?
    var currentChunk: Int?
    var isSpeaking = false
    var isPaused = false
    var loading = false                // waiting for the first audio from the cloud engine
    var lastError: String?

    override init() { super.init(); synth.delegate = self }

    enum Engine: String { case natural, system }
    var engine: Engine {
        get { Engine(rawValue: Prefs.shared.string("tts.engine", default: "natural")) ?? .natural }
        set { Prefs.shared.set(newValue.rawValue, "tts.engine") }
    }
    var naturalAvailable: Bool { ai?.apiKey(for: .gemini).map { !$0.isEmpty } ?? false }

    /// 0.75 to 1.5 times normal speed. Applies to both engines.
    var speed: Double {
        get { Prefs.shared.double("tts.speed", default: 1.0) }
        set { Prefs.shared.set(newValue, "tts.speed") }
    }
    var naturalVoice: String {
        get { Prefs.shared.string("tts.naturalVoice", default: "Charon") }
        set { Prefs.shared.set(newValue, "tts.naturalVoice") }
    }
    var style: String {
        get { "" }
        set { }
    }
    var voiceID: String {
        get { Prefs.shared.string("tts.voice") }
        set { Prefs.shared.set(newValue, "tts.voice") }
    }

    static func qualityRank(_ v: AVSpeechSynthesisVoice) -> Int { switch v.quality { case .premium: return 3; case .enhanced: return 2; default: return 1 } }
    static func qualityName(_ v: AVSpeechSynthesisVoice) -> String { switch v.quality { case .premium: return "Premium"; case .enhanced: return "Enhanced"; default: return "Standard" } }

    func voices() -> [AVSpeechSynthesisVoice] {
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        let region = Locale.current.region?.identifier ?? ""
        return AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(lang) && !$0.voiceTraits.contains(.isNoveltyVoice) }.sorted {
            let a = (Self.qualityRank($0), $0.language.hasSuffix(region) ? 1 : 0), b = (Self.qualityRank($1), $1.language.hasSuffix(region) ? 1 : 0)
            return a != b ? a > b : $0.name < $1.name
        }
    }
    func bestVoice() -> AVSpeechSynthesisVoice? {
        if !voiceID.isEmpty, let v = AVSpeechSynthesisVoice(identifier: voiceID) { return v }
        return voices().first ?? AVSpeechSynthesisVoice(language: Locale.current.identifier)
    }

    // MARK: Speaking

    func speak(_ chunks: [String], owner: String, startingAt: Int = 0) {
        stop()
        let texts = chunks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard texts.contains(where: { !$0.isEmpty }) else { return }
        self.owner = owner; lastError = nil
        if engine == .natural, naturalAvailable { speakNatural(texts, startingAt: startingAt) } else { speakSystem(texts, startingAt: startingAt) }
    }

    private func speakSystem(_ texts: [String], startingAt: Int) {
        let voice = bestVoice()
        for (i, t) in texts.enumerated() where i >= startingAt && !t.isEmpty {
            let u = AVSpeechUtterance(string: t)
            u.voice = voice; u.rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(speed)))
            u.preUtteranceDelay = i == startingAt ? 0 : 0.05
            indexByUtterance[ObjectIdentifier(u)] = i
            remaining += 1
            synth.speak(u)
        }
        isSpeaking = true; isPaused = false
    }

    /// Splits long paragraphs at sentence ends so audio starts quickly. Each piece remembers its paragraph for highlighting.
    private func pieces(_ texts: [String], startingAt: Int) -> [(index: Int, text: String)] {
        var out: [(Int, String)] = []
        for (i, t) in texts.enumerated() where i >= startingAt && !t.isEmpty {
            if t.count <= 650 { out.append((i, t)); continue }
            var cur = ""
            t.enumerateSubstrings(in: t.startIndex..<t.endIndex, options: .bySentences) { s, _, _, _ in
                guard let s else { return }
                if cur.count + s.count > 650, !cur.isEmpty { out.append((i, cur)); cur = "" }
                cur += s
            }
            if !cur.isEmpty { out.append((i, cur)) }
        }
        return out
    }

    private func speakNatural(_ texts: [String], startingAt: Int) {
        guard let ai, let client = ai.speechClient() else { speakSystem(texts, startingAt: startingAt); return }
        let parts = pieces(texts, startingAt: startingAt)
        let voice = naturalVoice, style = style
        isSpeaking = true; isPaused = false; loading = true
        cloudTask = Task { [weak self] in
            guard let self else { return }
            do {
                if self.ttsModels.isEmpty { self.ttsModels = await client.models() }
                let models = self.ttsModels
                func fetch(_ i: Int) -> Task<(wav: Data, model: String), Error> { Task { try await client.audio(for: parts[i].text, voice: voice, style: style, models: models) } }
                var next: Task<(wav: Data, model: String), Error>? = parts.isEmpty ? nil : fetch(0)
                for i in parts.indices {
                    guard let current = next else { break }
                    let result = try await current.value
                    next = i + 1 < parts.count ? fetch(i + 1) : nil      // fetch the next piece while this one plays
                    if Task.isCancelled { return }
                    ai.recordSpeech(model: result.model, text: parts[i].text)
                    self.loading = false
                    self.currentChunk = parts[i].index
                    try await self.play(result.wav)
                    if Task.isCancelled { return }
                }
                self.finish()
            } catch {
                if Task.isCancelled { return }
                // Fall back to the on-device voice rather than going silent.
                self.lastError = error.localizedDescription
                self.loading = false
                self.speakSystem(texts, startingAt: startingAt)
            }
        }
    }

    private func play(_ wav: Data) async throws {
        let p = try AVAudioPlayer(data: wav)
        p.enableRate = true; p.rate = Float(speed); p.delegate = self
        player = p
        p.prepareToPlay(); p.play()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in playbackDone = c }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in let c = self.playbackDone; self.playbackDone = nil; c?.resume() }
    }

    private func finish() { isSpeaking = false; isPaused = false; currentChunk = nil; owner = nil; loading = false; player = nil }

    func pause() {
        if let p = player, p.isPlaying { p.pause(); isPaused = true; return }
        if synth.pauseSpeaking(at: .word) { isPaused = true }
    }
    func resume() {
        if let p = player, isPaused { p.play(); isPaused = false; return }
        if synth.continueSpeaking() { isPaused = false }
    }
    func stop() {
        cloudTask?.cancel(); cloudTask = nil
        player?.stop(); player = nil
        if let c = playbackDone { playbackDone = nil; c.resume() }
        synth.stopSpeaking(at: .immediate)
        indexByUtterance = [:]; remaining = 0
        isSpeaking = false; isPaused = false; currentChunk = nil; owner = nil; loading = false
    }

    func preview() { speak(["Good morning, Xavi. Your calendar is clear, and there are two things worth a look before lunch."], owner: "preview") }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) {
        let id = ObjectIdentifier(u)
        Task { @MainActor in self.currentChunk = self.indexByUtterance[id] }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        let id = ObjectIdentifier(u)
        Task { @MainActor in
            self.indexByUtterance[id] = nil
            self.remaining = max(0, self.remaining - 1)
            if self.remaining == 0 { self.finish() }
        }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        let id = ObjectIdentifier(u)
        Task { @MainActor in self.indexByUtterance[id] = nil }
    }
}

/// Play / pause / stop for one piece of content.
struct ListenButton: View {
    let owner: String
    let chunks: () -> [String]
    private var speech: SpeechService { .shared }

    var body: some View {
        let mine = speech.owner == owner && speech.isSpeaking
        HStack(spacing: 6) {
            Button { mine ? (speech.isPaused ? speech.resume() : speech.pause()) : speech.speak(chunks(), owner: owner) } label: {
                HStack(spacing: 6) {
                    if mine && speech.loading { ProgressView().controlSize(.mini) } else { Image(systemName: mine && !speech.isPaused ? "pause.fill" : "speaker.wave.2").font(.system(size: 11)) }
                    Text(mine ? (speech.loading ? "Preparing…" : (speech.isPaused ? "Resume" : "Pause")) : "Listen")
                }
            }.buttonStyle(QuietButtonStyle(compact: true, selected: mine && !speech.isPaused))
            if mine { Button { speech.stop() } label: { Image(systemName: "stop.fill").font(.system(size: 11)) }.buttonStyle(QuietButtonStyle(compact: true)).accessibilityLabel("Stop reading").transition(.opacity.combined(with: .scale(scale: 0.85))) }
        }.animation(Motion.snappy, value: mine)
    }
}

/// Animation helpers that all honour Reduce Motion.
enum Motion {
    static var reduce: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var snappy: Animation? { reduce ? nil : .snappy(duration: 0.3) }
    static var gentle: Animation? { reduce ? nil : .easeOut(duration: 0.22) }
    static var spring: Animation? { reduce ? nil : .spring(response: 0.38, dampingFraction: 0.82) }
}

@MainActor func animated(_ body: () -> Void) {
    if let a = Motion.snappy { withAnimation(a, body) } else { body() }
}
