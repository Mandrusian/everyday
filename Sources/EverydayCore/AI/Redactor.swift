import Foundation

/// Strips low-value and sensitive noise from text before it is sent to a model.
public enum ContextRedactor {
    public static func clean(_ text: String, limit: Int = 4000) -> String {
        var lines: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "--" || line == "-- " || line.hasPrefix("-- ") && line.count < 4 { break }          // signature delimiter
            if line.hasPrefix(">") { continue }                                                          // quoted reply
            if line.range(of: #"^On .+ wrote:$"#, options: .regularExpression) != nil { break }
            if line.lowercased().hasPrefix("sent from my") { break }
            if line.range(of: #"^-{2,}\s*(Forwarded|Original) message"#, options: [.regularExpression, .caseInsensitive]) != nil { break }
            lines.append(line)
        }
        var s = lines.joined(separator: "\n")
        s = s.replacingOccurrences(of: #"(https?://[^\s?)>\]]+)\?[^\s)>\]]*"#, with: "$1", options: .regularExpression)  // tracking params
        s = s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.count > limit ? String(s.prefix(limit)) + " […]" : s
    }
}
