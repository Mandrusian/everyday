import Foundation
import CryptoKit

public struct FeedHealth: Codable, Hashable, Sendable {
    public var url: String
    public var lastFetched: Date?
    public var lastError: String?
    public var itemCount: Int
    public var etag: String?
    public var lastModified: String?
}

public final class NewsService: @unchecked Sendable {
    private let db: Database
    private let prefs: Prefs
    public let interests: InterestModel
    private let session: URLSession

    public init(db: Database, interests: InterestModel, prefs: Prefs = .shared) {
        self.db = db; self.interests = interests; self.prefs = prefs
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.httpAdditionalHeaders = ["User-Agent": "everyday./0.1 (personal feed reader)", "Accept": "application/rss+xml, application/atom+xml, application/xml, text/xml, */*"]
        self.session = URLSession(configuration: c)
    }

    // MARK: Sources

    public func sources() -> [FeedSource] {
        if let saved: [FeedSource] = try? db.all("feed"), !saved.isEmpty {
            // merge in new defaults added by app updates
            var out = saved
            for d in FeedCatalog.defaults where !saved.contains(where: { $0.url == d.url }) { out.append(d) }
            return out.sorted { $0.name < $1.name }
        }
        return FeedCatalog.defaults.sorted { $0.name < $1.name }
    }

    public func save(source: FeedSource) { try? db.put("feed", id: source.url, source) }
    public func saveAll(_ s: [FeedSource]) { for x in s { save(source: x) } }
    public func remove(source: FeedSource) { try? db.delete("feed", id: source.url); try? db.put("feedRemoved", id: source.url, true) }
    public func health() -> [String: FeedHealth] {
        let h: [FeedHealth] = (try? db.all("feedHealth")) ?? []
        return Dictionary(uniqueKeysWithValues: h.map { ($0.url, $0) })
    }

    public static func articleID(_ link: String) -> String {
        var s = link
        if let u = URL(string: link), var c = URLComponents(url: u, resolvingAgainstBaseURL: false) {
            c.query = nil; c.fragment = nil
            s = (c.string ?? link).lowercased()
        }
        return SHA256.hash(data: Data(s.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Refresh

    @discardableResult
    public func refresh(onlyCategories: [NewsCategory]? = nil, force: Bool = false) async -> (articles: Int, failures: Int) {
        var list = sources().filter { $0.enabled }
        if let cats = onlyCategories { list = list.filter { s in s.categories.contains(where: cats.contains) } }
        let healthMap = health()
        var total = 0, failed = 0
        await withTaskGroup(of: (FeedSource, Result<[Article], Error>, FeedHealth).self) { group in
            var running = 0
            var iterator = list.makeIterator()
            func addNext() -> Bool {
                guard let src = iterator.next() else { return false }
                let h = healthMap[src.url]
                group.addTask { [self] in
                    var health = h ?? FeedHealth(url: src.url, lastFetched: nil, lastError: nil, itemCount: 0, etag: nil, lastModified: nil)
                    do {
                        let articles = try await fetch(src, health: &health, force: force)
                        health.lastError = nil; health.lastFetched = Date()
                        return (src, .success(articles), health)
                    } catch {
                        health.lastError = error.localizedDescription; health.lastFetched = Date()
                        return (src, .failure(error), health)
                    }
                }
                return true
            }
            while running < 8, addNext() { running += 1 }
            for await (_, result, health) in group {
                switch result {
                case .success(let arts):
                    var h = health; if !arts.isEmpty { h.itemCount = arts.count }
                    try? db.put("feedHealth", id: h.url, h)
                    for a in arts { try? db.put("article", id: a.id, sort: a.published.timeIntervalSince1970, a) }
                    total += arts.count
                case .failure:
                    try? db.put("feedHealth", id: health.url, health); failed += 1
                }
                if addNext() {} 
            }
        }
        prune()
        return (total, failed)
    }

    private func fetch(_ src: FeedSource, health: inout FeedHealth, force: Bool) async throws -> [Article] {
        guard let url = URL(string: src.url) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        if !force, let e = health.etag { req.setValue(e, forHTTPHeaderField: "If-None-Match") }
        if !force, let m = health.lastModified { req.setValue(m, forHTTPHeaderField: "If-Modified-Since") }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 304 { return [] }
        guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]) }
        health.etag = http.value(forHTTPHeaderField: "ETag")
        health.lastModified = http.value(forHTTPHeaderField: "Last-Modified")
        let items = FeedParser.parse(data)
        if items.isEmpty { throw URLError(.cannotParseResponse, userInfo: [NSLocalizedDescriptionKey: "No items found"]) }
        return items.compactMap { it in
            guard !it.title.isEmpty, !it.link.isEmpty else { return nil }
            let summaryText = HTMLText.plain(it.summary.isEmpty ? it.content : it.summary)
            return Article(id: Self.articleID(it.link), title: it.title, link: it.link, source: src.name, feedURL: src.url,
                           summary: String(summaryText.prefix(600)), imageURL: it.image, published: min(it.date ?? Date(), Date()),
                           categories: src.categories, trust: src.trust, outsideBubble: src.outsideBubble)
        }
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-14 * 86400).timeIntervalSince1970
        _ = try? db.exec("DELETE FROM docs WHERE kind='article' AND sort < ? AND id NOT IN (SELECT id FROM docs WHERE kind='saved')", [.double(cutoff)])
    }

    // MARK: Stories

    public func articles() -> [Article] { (try? db.all("article", limit: 4000)) ?? [] }

    /// Coupon, promo-code and deal-roundup headlines are advertising, not news.
    static let promoPattern = try! NSRegularExpression(pattern: #"(coupon|promo(tion(al)?)? codes?|discount codes?|voucher|\d+% off|\bdeals? (of the|on)\b|best .{0,30}\bdeals\b|black friday|cyber monday|prime day|sale ends|gift guide|where to buy)"#, options: .caseInsensitive)
    public static func isPromo(_ title: String) -> Bool { promoPattern.firstMatch(in: title, range: NSRange(location: 0, length: (title as NSString).length)) != nil }

    /// Groups near-duplicate headlines into stories, drops stale items and ranks by interest, recency and trust.
    public func stories(category: NewsCategory? = nil, limit: Int = 60) -> [Story] {
        let freshness = prefs.double(Prefs.Key.freshnessHours, default: 48)
        let cutoff = Date().addingTimeInterval(-freshness * 3600)
        let muted = prefs.strings(Prefs.Key.mutedTopics).map { $0.lowercased() }.filter { !$0.isEmpty }
        var arts = articles().filter { $0.published >= cutoff }
        if !muted.isEmpty { arts = arts.filter { a in let t = (a.title + " " + a.summary).lowercased(); return !muted.contains(where: t.contains) } }
        if prefs.bool("newsHidePromos", default: true) { arts = arts.filter { !Self.isPromo($0.title) } }
        if let c = category { arts = arts.filter { $0.categories.contains(c) } }
        let includeOutside = prefs.bool(Prefs.Key.outsideBubble, default: true)
        arts.sort { $0.published > $1.published }

        var clusters: [(lead: Article, tokens: Set<String>, others: [Article])] = []
        for a in arts {
            let t = Self.titleTokens(a.title)
            if let idx = clusters.firstIndex(where: { Self.similar($0.tokens, t) }) {
                clusters[idx].others.append(a)
                clusters[idx].tokens.formUnion(t)
                if a.trust > clusters[idx].lead.trust { let old = clusters[idx].lead; clusters[idx].lead = a; clusters[idx].others.removeAll { $0.id == a.id }; clusters[idx].others.append(old) }
            } else {
                clusters.append((a, t, []))
            }
        }
        let now = Date()
        var stories = clusters.map { c -> Story in
            let ageH = max(0, now.timeIntervalSince(c.lead.published) / 3600)
            let recency = exp(-ageH / 18)
            let interest = interests.score(c.lead)
            let coverage = log2(Double(1 + c.others.count)) * 0.6
            let trust = Double(c.lead.trust - 2) * 0.3
            return Story(lead: c.lead, others: c.others, score: interest * 0.5 + recency * 3 + coverage + trust)
        }
        stories.sort { $0.score > $1.score }
        // Exploration: keep roughly one in ten slots for outside-your-bubble sources.
        var main = stories.filter { !$0.lead.outsideBubble }
        let outside = stories.filter { $0.lead.outsideBubble }
        if includeOutside {
            let slots = max(1, limit / 10)
            for (i, s) in outside.prefix(slots).enumerated() {
                let pos = min(main.count, 4 + i * 9)
                main.insert(s, at: pos)
            }
        }
        return Array(main.prefix(limit))
    }

    public static func titleTokens(_ t: String) -> Set<String> {
        let words = t.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return Set(words.filter { $0.count > 2 && !InterestModel.stopwords.contains($0) })
    }

    public static func similar(_ a: Set<String>, _ b: Set<String>) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        let inter = Double(a.intersection(b).count)
        let jaccard = inter / Double(a.union(b).count)
        let overlap = inter / Double(min(a.count, b.count))
        return jaccard >= 0.45 || (overlap >= 0.75 && inter >= 4)
    }

    // MARK: Saved + AI cache

    public func isSaved(_ id: String) -> Bool { (try? db.get("saved", id: id, as: Article.self)) != nil }
    public func toggleSaved(_ a: Article) {
        if isSaved(a.id) { try? db.delete("saved", id: a.id) } else { try? db.put("saved", id: a.id, sort: Date().timeIntervalSince1970, a) }
    }
    public func savedArticles() -> [Article] { (try? db.all("saved")) ?? [] }

    public func cachedAI(_ id: String) -> ArticleAI? { try? db.get("articleAI", id: id) }
    public func cacheAI(_ v: ArticleAI) { try? db.put("articleAI", id: v.articleId, v) }

    public func react(_ a: Article, _ r: Reaction) { interests.record(a, reaction: Double(r.rawValue)) }

    /// Real articles for the onboarding swipe deck, spread across the chosen categories.
    public func swipeDeck(categories: [NewsCategory], count: Int = 24) -> [Article] {
        let arts = articles().sorted { $0.published > $1.published }
        var perCat: [[Article]] = categories.map { c in arts.filter { $0.categories.contains(c) && !$0.outsideBubble && $0.trust >= 2 } }
        var out: [Article] = []
        var seen = Set<String>(), seenTitles: [Set<String>] = []
        var i = 0
        while out.count < count, perCat.contains(where: { !$0.isEmpty }) {
            let idx = i % perCat.count
            i += 1
            while let a = perCat[idx].first {
                perCat[idx].removeFirst()
                let t = Self.titleTokens(a.title)
                if seen.contains(a.id) || seenTitles.contains(where: { Self.similar($0, t) }) { continue }
                seen.insert(a.id); seenTitles.append(t); out.append(a); break
            }
            if i > count * 20 { break }
        }
        return out
    }
}
