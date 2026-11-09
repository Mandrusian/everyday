import Foundation

/// The small subset of markdown that AI-written text uses: headings, bullet and numbered lists, **bold**, *italics*, `code` and [links](url).
public enum Markdown {
    public enum Block: Sendable, Hashable {
        case paragraph(String)
        case bullet(String)
        case numbered(String, String)   // marker ("1."), text
    }

    static let bulletRE = try! NSRegularExpression(pattern: #"^\s*[-*•+]\s+(.*)$"#)
    static let numberRE = try! NSRegularExpression(pattern: #"^\s*(\d{1,3}[.)])\s+(.*)$"#)

    /// Splits text into paragraphs and list items. Consecutive plain lines join into one paragraph.
    public static func blocks(_ text: String) -> [Block] {
        var out: [Block] = [], para: [String] = []
        func flush() { let p = para.joined(separator: " ").trimmingCharacters(in: .whitespaces); if !p.isEmpty { out.append(.paragraph(p)) }; para = [] }
        for raw in text.components(separatedBy: "\n") {
            let ns = raw as NSString, r = NSRange(location: 0, length: ns.length)
            if let m = bulletRE.firstMatch(in: raw, range: r) { flush(); out.append(.bullet(ns.substring(with: m.range(at: 1)))) }
            else if let m = numberRE.firstMatch(in: raw, range: r) { flush(); out.append(.numbered(ns.substring(with: m.range(at: 1)), ns.substring(with: m.range(at: 2)))) }
            else if raw.trimmingCharacters(in: .whitespaces).isEmpty { flush() }
            else { para.append(raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)) }
        }
        flush()
        return out
    }

    /// Inline markup removed: for speech, notifications, headings and previews.
    public static func plain(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        for mark in ["**", "__", "`"] { t = t.replacingOccurrences(of: mark, with: "") }
        t = t.replacingOccurrences(of: #"(?<![\w*])\*(?!\s)([^*\n]+?)(?<!\s)\*(?![\w*])"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"^\s*#{1,6}\s+"#, with: "", options: .regularExpression)
        return t
    }

    /// Bullets and numbering turned into readable text, for speech and notifications.
    public static func plainText(_ s: String) -> String {
        blocks(s).map { b -> String in
            switch b { case .paragraph(let t), .bullet(let t): return plain(t); case .numbered(let n, let t): return n + " " + plain(t) }
        }.joined(separator: "\n")
    }
}
