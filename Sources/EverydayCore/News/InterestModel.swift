import Foundation
import NaturalLanguage

/// On-device preference model. Learns from reactions: per-category, per-source and per-keyword weights
/// with time decay, so recent behaviour counts more. Nothing leaves the Mac.
public struct InterestProfile: Codable, Sendable {
    public var categoryWeights: [String: Double] = [:]
    public var sourceWeights: [String: Double] = [:]
    public var keywordWeights: [String: Double] = [:]
    public var updatedAt: Date = Date()
    public var reactionCount: Int = 0
}

public final class InterestModel: @unchecked Sendable {
    private let db: Database
    private var profile: InterestProfile
    private let lock = NSLock()
    static let halfLifeDays = 45.0

    public init(db: Database) {
        self.db = db
        self.profile = (try? db.get("profile", id: "interest")) ?? InterestProfile()
        decay()
    }

    public var snapshot: InterestProfile { lock.withLock { profile } }

    private func decay() {
        let days = Date().timeIntervalSince(profile.updatedAt) / 86400
        guard days > 0.5 else { return }
        let f = pow(0.5, days / Self.halfLifeDays)
        profile.categoryWeights = profile.categoryWeights.mapValues { $0 * f }
        profile.sourceWeights = profile.sourceWeights.mapValues { $0 * f }
        profile.keywordWeights = profile.keywordWeights.mapValues { $0 * f }.filter { abs($0.value) > 0.05 }
        profile.updatedAt = Date()
    }

    public static func tokens(_ text: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text.lowercased()
        var out: [String] = []
        tagger.enumerateTags(in: tagger.string!.startIndex..<tagger.string!.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            if tag == .noun || tag == .otherWord || tag == .verb {
                let w = String(tagger.string![range])
                if w.count > 3, !stopwords.contains(w) { out.append(w) }
            }
            return true
        }
        return out
    }

    static let stopwords: Set<String> = ["that", "this", "with", "from", "have", "will", "your", "about", "after", "over", "more", "than", "what", "when", "they", "their", "says", "said", "could", "would", "into", "just", "been", "were", "being", "also", "year", "years", "says"]

    public func seed(categories: [NewsCategory]) {
        lock.withLock {
            for c in categories { profile.categoryWeights[c.rawValue, default: 0] += 2 }
            persist()
        }
    }

    public func record(_ article: Article, reaction: Double) {
        lock.withLock {
            decay()
            for c in article.categories { profile.categoryWeights[c.rawValue, default: 0] += reaction * 0.8 }
            profile.sourceWeights[article.source, default: 0] += reaction * 0.5
            for k in Set(Self.tokens(article.title)).prefix(8) { profile.keywordWeights[k, default: 0] += reaction * 0.4 }
            profile.reactionCount += 1
            profile.updatedAt = Date()
            persist()
        }
    }

    public func score(_ a: Article) -> Double {
        lock.withLock {
            var s = 0.0
            for c in a.categories { s += profile.categoryWeights[c.rawValue] ?? 0 }
            s += profile.sourceWeights[a.source] ?? 0
            for k in Set(Self.tokens(a.title)) { s += min(profile.keywordWeights[k] ?? 0, 2.0) * 0.6 }
            return s
        }
    }

    public func topInterests(_ n: Int = 6) -> [(String, Double)] {
        lock.withLock { Array(profile.categoryWeights.sorted { $0.value > $1.value }.prefix(n)).map { ($0.key, $0.value) } }
    }

    public func reset() {
        lock.withLock { profile = InterestProfile(); persist() }
    }

    public func exportJSON() -> Data? {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601
        return lock.withLock { try? e.encode(profile) }
    }

    public func importJSON(_ data: Data) throws {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let p = try d.decode(InterestProfile.self, from: data)
        lock.withLock { profile = p; persist() }
    }

    private func persist() { try? db.put("profile", id: "interest", profile) }
}
