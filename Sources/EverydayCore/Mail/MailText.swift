import Foundation

/// Turns the plain-text part of an email into something readable: links get their own words instead of
/// a wall of tracking URLs, soft-wrapped lines are rejoined, and leftover link-only lines are removed.
public enum MailText {
    public struct Piece: Equatable, Sendable {
        public var text: String
        public var link: URL?
    }

    static let labelled = try! NSRegularExpression(pattern: #"([^\n<>]*?[^\s<>|])\s*<<?(https?://[^\s<>]+)>>?"#)
    static let bareAngle = try! NSRegularExpression(pattern: #"<(https?://[^\s<>]+)>"#)
    static let bareURL = try! NSRegularExpression(pattern: #"https?://[^\s<>()]+"#)

    /// Rejoins lines that plain-text email wraps with two trailing spaces, and tidies blank lines.
    public static func unwrap(_ body: String) -> String {
        var out = ""
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            if line.hasSuffix("  ") && i < lines.count - 1 { out += line.trimmingCharacters(in: .whitespaces) + " " }
            else { out += line + (i < lines.count - 1 ? "\n" : "") }
        }
        return out.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The body as text pieces, some of them links.
    public static func pieces(_ body: String) -> [Piece] {
        var text = unwrap(body)
        // Lines that are nothing but a link in angle brackets (image and tracking links) carry no words: drop them.
        text = text.components(separatedBy: "\n").filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return !(t.hasPrefix("<http") && t.hasSuffix(">") && !t.dropFirst().contains("<"))
        }.joined(separator: "\n")
        var out: [Piece] = []
        let ns = text as NSString
        var last = 0
        // "Set up a passkey<<https://…>>" and "Unsubscribe <https://…>": the words before become the link.
        for m in labelled.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let labelRange = m.range(at: 1), urlRange = m.range(at: 2)
            // Only take the last few words of the line as the label, so a long sentence isn't all link.
            var label = ns.substring(with: labelRange)
            var labelStart = labelRange.location
            let words = label.split(separator: " ", omittingEmptySubsequences: false)
            if words.count > 6 {
                let keep = words.suffix(4).joined(separator: " ")
                labelStart += (label as NSString).length - (keep as NSString).length
                label = keep
            }
            if labelStart > last { out.append(Piece(text: ns.substring(with: NSRange(location: last, length: labelStart - last)), link: nil)) }
            let url = URL(string: ns.substring(with: urlRange))
            out.append(Piece(text: label.trimmingCharacters(in: .whitespaces), link: url))
            last = m.range.location + m.range.length
        }
        if last < ns.length { out.append(Piece(text: ns.substring(from: last), link: nil)) }
        // Any other bare URLs show as their site name only.
        return out.flatMap { p -> [Piece] in
            guard p.link == nil else { return [p] }
            var res: [Piece] = []
            let s = p.text as NSString
            var at = 0
            for m in bareURL.matches(in: p.text, range: NSRange(location: 0, length: s.length)) {
                if m.range.location > at { res.append(Piece(text: s.substring(with: NSRange(location: at, length: m.range.location - at)), link: nil)) }
                let raw = s.substring(with: m.range)
                let u = URL(string: raw)
                res.append(Piece(text: u?.host.map { $0.replacingOccurrences(of: "www.", with: "") } ?? raw, link: u))
                at = m.range.location + m.range.length
            }
            if at < s.length { res.append(Piece(text: s.substring(from: at), link: nil)) }
            return res
        }.filter { !$0.text.isEmpty }
    }

    /// Plain text with links reduced to their words, for summaries and search snippets.
    public static func readable(_ body: String) -> String { pieces(body).map(\.text).joined() }
}
