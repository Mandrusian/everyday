import Foundation

/// "pay rent friday 5pm high" → title "pay rent", due Friday 17:00, high priority. Runs on device.
public enum QuickAdd {
    public struct Result: Equatable, Sendable { public var title: String; public var due: Date?; public var priority: TaskPriority; public var repeats: TaskRepeat? = nil }

    public static func parse(_ input: String, now: Date = Date(), calendar: Calendar = .current) -> Result {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var priority = TaskPriority.medium
        // priority words and marks
        let rules: [(String, TaskPriority)] = [(#"(?i)(?:^|\s)(?:!{3}|urgent|asap|high(?: priority)?)(?=\s|$)"#, .high), (#"(?i)(?:^|\s)(?:low(?: priority)?|someday)(?=\s|$)"#, .low)]
        for (pattern, p) in rules {
            if let r = text.range(of: pattern, options: .regularExpression) { priority = p; text.removeSubrange(r) }
        }
        // repeats: "every day", "weekly", "every friday" (the weekday is kept so it also sets the first due date)
        var repeats: TaskRepeat?
        let rep: [(String, TaskRepeat)] = [(#"(?i)\bevery\s+weekday\b"#, .weekdays), (#"(?i)\b(?:every\s+day|daily)\b"#, .daily), (#"(?i)\b(?:every\s+week|weekly)\b"#, .weekly), (#"(?i)\b(?:every\s+month|monthly)\b"#, .monthly), (#"(?i)\b(?:every\s+year|yearly|annually)\b"#, .yearly)]
        for (pattern, r) in rep { if let m = text.range(of: pattern, options: .regularExpression) { repeats = r; text.removeSubrange(m); break } }
        if repeats == nil, let m = text.range(of: #"(?i)\bevery\s+(?=(?:mon|tues|wednes|thurs|fri|satur|sun)day\b)"#, options: .regularExpression) { repeats = .weekly; text.removeSubrange(m) }
        // date and time
        var due: Date?
        if let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let ns = text as NSString
            if let m = det.matches(in: text, range: NSRange(location: 0, length: ns.length)).first, let d = m.date {
                var date = d
                // "friday" alone should mean the coming Friday, never today in the past
                if date < now, !calendar.isDateInToday(date) { date = calendar.date(byAdding: .day, value: 7, to: date) ?? date }
                let hasTime = text.range(of: #"(?i)\d\s?(am|pm)|\d{1,2}:\d{2}|noon|midnight|tonight|morning|evening|afternoon"#, options: .regularExpression, range: text.range(of: ns.substring(with: m.range))) != nil
                due = hasTime ? date : calendar.startOfDay(for: date)
                text = ns.replacingCharacters(in: m.range, with: "")
            }
        }
        // tidy leftovers like "on", "by", "at" dangling at the end
        text = text.replacingOccurrences(of: #"(?i)\s+(on|by|at|for|due)\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(title: text.isEmpty ? input.trimmingCharacters(in: .whitespacesAndNewlines) : text, due: due, priority: priority, repeats: repeats)
    }
}

/// OPML import and export for news sources.
public enum OPML {
    public static func export(_ sources: [FeedSource]) -> String {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }
        let body = sources.map { "    <outline type=\"rss\" text=\"\(esc($0.name))\" title=\"\(esc($0.name))\" xmlUrl=\"\(esc($0.url))\" category=\"\(esc($0.categories.map(\.rawValue).joined(separator: ",")))\"/>" }.joined(separator: "\n")
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<opml version=\"2.0\">\n  <head><title>everyday. sources</title></head>\n  <body>\n\(body)\n  </body>\n</opml>\n"
    }

    public static func parse(_ data: Data) -> [FeedSource] {
        final class P: NSObject, XMLParserDelegate {
            var out: [FeedSource] = []
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName q: String?, attributes a: [String: String] = [:]) {
                guard name == "outline", let url = a["xmlUrl"] ?? a["xmlurl"], url.hasPrefix("http") else { return }
                let cats = (a["category"] ?? "").split(separator: ",").compactMap { NewsCategory(rawValue: String($0).trimmingCharacters(in: .whitespaces).lowercased()) }
                out.append(FeedSource(name: a["text"] ?? a["title"] ?? (URL(string: url)?.host ?? url), url: url, categories: cats.isEmpty ? [.technology] : cats, trust: 2))
            }
        }
        let p = P(); let x = XMLParser(data: data); x.delegate = p; x.parse()
        var seen = Set<String>()
        return p.out.filter { seen.insert($0.url).inserted }
    }
}
