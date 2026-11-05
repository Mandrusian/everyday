import Foundation

public struct ExtractedArticle: Sendable, Hashable {
    public var title: String
    public var paragraphs: [String]
    public var byline: String?
    public var imageURL: String?
    public var text: String { paragraphs.joined(separator: "\n\n") }
}

/// Dependency-free readability: finds the main article container and returns its paragraphs.
public enum ArticleExtractor {
    public static func fetch(_ link: String) async throws -> ExtractedArticle {
        guard let url = URL(string: link) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else { throw URLError(.badServerResponse) }
        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return extract(html: html)
    }

    public static func extract(html raw: String) -> ExtractedArticle {
        var html = raw
        for tag in ["script", "style", "noscript", "svg", "form", "nav", "footer", "aside", "header", "figure", "iframe"] {
            html = html.replacingOccurrences(of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        html = html.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        let title = meta(raw, "og:title") ?? firstMatch(raw, "<title[^>]*>([\\s\\S]*?)</title>").map(HTMLText.plain) ?? ""
        let image = meta(raw, "og:image")
        let byline = meta(raw, "author") ?? meta(raw, "article:author")

        var container = html
        if let art = firstMatch(html, "<article[^>]*>([\\s\\S]*?)</article>") { container = art }
        else if let main = firstMatch(html, "<main[^>]*>([\\s\\S]*?)</main>") { container = main }

        var paras: [String] = []
        let re = try? NSRegularExpression(pattern: "<p[^>]*>([\\s\\S]*?)</p>", options: [.caseInsensitive])
        let ns = container as NSString
        re?.enumerateMatches(in: container, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m, m.numberOfRanges > 1 else { return }
            let t = HTMLText.plain(ns.substring(with: m.range(at: 1))).replacingOccurrences(of: "\n", with: " ")
            if t.count >= 40, !t.lowercased().hasPrefix("copyright"), !t.lowercased().contains("sign up for") , !t.lowercased().contains("subscribe to our") { paras.append(t) }
        }
        return ExtractedArticle(title: title, paragraphs: paras, byline: byline, imageURL: image)
    }

    private static func meta(_ html: String, _ name: String) -> String? {
        for pattern in ["<meta[^>]+(?:property|name)=[\"']\(name)[\"'][^>]+content=[\"']([^\"']*)[\"']", "<meta[^>]+content=[\"']([^\"']*)[\"'][^>]+(?:property|name)=[\"']\(name)[\"']"] {
            if let v = firstMatch(html, pattern) { return HTMLText.decodeEntities(v) }
        }
        return nil
    }

    private static func firstMatch(_ s: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)), m.numberOfRanges > 1 else { return nil }
        return (s as NSString).substring(with: m.range(at: 1))
    }
}
