import Foundation

/// Highlight tags the AI adds to briefings and summaries so they can be skimmed:
/// <<u|urgent or deadline>> <<d|date or time>> <<p|person or organisation>> <<n|amount, number or place>>
public enum SkimMarkup {
    public enum Kind: String, Sendable { case urgent = "u", date = "d", person = "p", number = "n" }
    public struct Segment: Sendable, Hashable { public var text: String; public var kind: Kind? }

    /// Prompt text that teaches a model the tags.
    public static let promptRule = "For skim reading, wrap the few phrases a reader must not miss in these tags, never nested, each under six words, at most eight in total: <<u|…>> for anything urgent or a deadline, <<d|…>> for dates and times, <<p|…>> for people and organisations, <<n|…>> for amounts, numbers and places. Everything else stays plain. Do not use markdown or any other markup."

    static let regex = try! NSRegularExpression(pattern: #"<<([udpn])\|(.*?)>>"#, options: [.dotMatchesLineSeparators])

    public static func segments(_ s: String) -> [Segment] {
        var out: [Segment] = []
        let ns = s as NSString
        var last = 0
        for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > last { out.append(Segment(text: ns.substring(with: NSRange(location: last, length: m.range.location - last)), kind: nil)) }
            out.append(Segment(text: ns.substring(with: m.range(at: 2)), kind: Kind(rawValue: ns.substring(with: m.range(at: 1)))))
            last = m.range.location + m.range.length
        }
        if last < ns.length { out.append(Segment(text: ns.substring(from: last), kind: nil)) }
        // A model that opened a tag and never closed it should not leak "<<u|" into the UI.
        return out.map { seg in
            var t = seg.text
            t = t.replacingOccurrences(of: #"<<[udpn]\|"#, with: "", options: .regularExpression).replacingOccurrences(of: ">>", with: "")
            return Segment(text: t, kind: seg.kind)
        }
    }

    /// Keeps the first `max` highlights and turns any further ones into plain text, so a chatty model cannot colour the whole paragraph.
    public static func limit(_ s: String, max: Int = 8) -> String {
        var n = 0
        return segments(s).map { seg -> String in
            guard let k = seg.kind else { return seg.text }
            n += 1
            return n <= max ? "<<\(k.rawValue)|\(seg.text)>>" : seg.text
        }.joined()
    }

    // MARK: Local fallback
    // Models sometimes skip the tags on long inputs, so the app can highlight dates, times, amounts and urgent words itself.

    private static let months = "(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)"
    private static let days = "(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)"
    private static let rules: [(Kind, String)] = [
        (.urgent, #"\b(?:immediately|urgent(?:ly)?|overdue|asap|final (?:reminder|notice|warning)|unrecognized|unrecognised|suspicious|security alert|expires?(?: today| tomorrow)?|deadline|due (?:today|tomorrow|now))\b"#),
        (.date, "\\b\(months) \\d{1,2}(?:st|nd|rd|th)?(?:,? \\d{4})?\\b"),
        (.date, "\\b\\d{1,2}(?:st|nd|rd|th)? \(months)(?:,? \\d{4})?\\b"),
        (.date, "\\b(?:today|tomorrow|tonight|this (?:morning|afternoon|evening)|\(days))\\b"),
        (.date, #"\b\d{1,2}:\d{2}(?:\s?(?:am|pm))?\b|\b\d{1,2}\s?(?:am|pm)\b"#),
        (.number, #"(?:A\$|\$|£|€)\s?\d[\d,]*(?:\.\d+)?(?: ?(?:billion|million|k))?"#),
        (.number, #"\b\d+(?:\.\d+)?\s?(?:%|percent|°C|°F|°)"#),
    ]

    /// Adds tags to plain text. `names` are people, organisations and places worth colouring (sender names, the user's city).
    public static func autoTag(_ text: String, names: [String] = [], places: [String] = [], max limit: Int = 8) -> String {
        guard !hasTags(text) else { return text }
        let ns = text as NSString
        var hits: [(range: NSRange, kind: Kind)] = []
        for (kind, pattern) in rules {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) { hits.append((m.range, kind)) }
        }
        for (list, kind) in [(names, Kind.person), (places, Kind.number)] {
            for n in list where n.count >= 3 {
                var from = 0
                while from < ns.length {
                    let r = ns.range(of: n, options: .caseInsensitive, range: NSRange(location: from, length: ns.length - from))
                    if r.location == NSNotFound { break }
                    hits.append((r, kind)); from = r.location + r.length
                }
            }
        }
        // earliest first; on overlap keep the longer one
        hits.sort { $0.range.location != $1.range.location ? $0.range.location < $1.range.location : $0.range.length > $1.range.length }
        var chosen: [(range: NSRange, kind: Kind)] = []
        for h in hits { if let last = chosen.last, NSIntersectionRange(last.range, h.range).length > 0 { continue }; chosen.append(h) }
        // when there are too many, prefer urgent, then dates, then names and numbers
        if chosen.count > limit {
            let rank: [Kind: Int] = [.urgent: 0, .date: 1, .person: 2, .number: 3]
            let keep = Set(chosen.enumerated().sorted { (rank[$0.element.kind] ?? 9, $0.offset) < (rank[$1.element.kind] ?? 9, $1.offset) }.prefix(limit).map(\.offset))
            chosen = chosen.enumerated().filter { keep.contains($0.offset) }.map(\.element)
        }
        var out = "", last = 0
        for c in chosen {
            out += ns.substring(with: NSRange(location: last, length: c.range.location - last))
            out += "<<\(c.kind.rawValue)|\(ns.substring(with: c.range))>>"
            last = c.range.location + c.range.length
        }
        return out + ns.substring(from: last)
    }

    public static func strip(_ s: String) -> String { segments(s).map(\.text).joined() }
    public static func hasTags(_ s: String) -> Bool { s.contains("<<") && regex.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil }
}
