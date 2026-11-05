import Foundation

public struct ParsedItem: Sendable {
    public var title = ""
    public var link = ""
    public var guid = ""
    public var summary = ""
    public var content = ""
    public var image: String?
    public var date: Date?
}

public enum HTMLText {
    static let entities: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ndash": "–", "mdash": "—", "hellip": "…", "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“", "copy": "©"]

    public static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].prefix(10).firstIndex(of: ";") {
                let name = String(s[s.index(after: i)..<semi])
                if name.hasPrefix("#") {
                    let num = name.dropFirst().hasPrefix("x") || name.dropFirst().hasPrefix("X") ? UInt32(name.dropFirst(2), radix: 16) : UInt32(name.dropFirst())
                    if let n = num, let u = Unicode.Scalar(n) { out.unicodeScalars.append(u); i = s.index(after: semi); continue }
                } else if let r = entities[name] { out += r; i = s.index(after: semi); continue }
            }
            out.append(s[i]); i = s.index(after: i)
        }
        return out
    }

    public static func plain(_ html: String) -> String {
        var s = html.replacingOccurrences(of: #"<(script|style)[^>]*>[\s\S]*?</\1>"#, with: " ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<br\s*/?>|</p>|</div>|</li>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        s = decodeEntities(s)
        s = s.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n\s*\n+"#, with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Parses RSS 2.0, RSS 1.0 (RDF) and Atom.
public final class FeedParser: NSObject, XMLParserDelegate {
    private var items: [ParsedItem] = []
    private var current: ParsedItem?
    private var text = ""
    private var path: [String] = []

    public static func parse(_ data: Data) -> [ParsedItem] {
        let p = FeedParser()
        let x = XMLParser(data: data)
        x.delegate = p
        x.shouldProcessNamespaces = false
        x.parse()
        return p.items
    }

    public func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes a: [String: String] = [:]) {
        path.append(name)
        text = ""
        if name == "item" || name == "entry" { current = ParsedItem() }
        guard current != nil else { return }
        switch name {
        case "link":
            if let href = a["href"], (a["rel"] ?? "alternate") == "alternate", current?.link.isEmpty == true { current?.link = href }
        case "media:thumbnail", "media:content":
            if let u = a["url"], current?.image == nil, (a["medium"] ?? "image") == "image" || name == "media:thumbnail" { current?.image = u }
        case "enclosure":
            if let u = a["url"], (a["type"] ?? "").hasPrefix("image"), current?.image == nil { current?.image = u }
        default: break
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    public func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { text += String(decoding: CDATABlock, as: UTF8.self) }

    public func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        defer { path.removeLast() }
        guard current != nil else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "title": if current?.title.isEmpty == true { current?.title = HTMLText.plain(t) }
        case "link": if current?.link.isEmpty == true, !t.isEmpty { current?.link = t }
        case "guid", "id": if current?.guid.isEmpty == true { current?.guid = t }
        case "description", "summary": if current?.summary.isEmpty == true { current?.summary = t }
        case "content:encoded", "content": if current?.content.isEmpty == true { current?.content = t }
        case "pubDate", "published", "updated", "dc:date":
            if current?.date == nil { current?.date = Self.parseDate(t) }
        case "item", "entry":
            if var c = current {
                if c.image == nil {
                    let html = c.content.isEmpty ? c.summary : c.content
                    if let r = html.range(of: #"<img[^>]+src=["']([^"']+)["']"#, options: .regularExpression) {
                        let tag = String(html[r])
                        if let s = tag.range(of: #"src=["']([^"']+)["']"#, options: .regularExpression) {
                            c.image = String(tag[s]).dropFirst(5).dropLast(1).description
                        }
                    }
                }
                items.append(c)
            }
            current = nil
        default: break
        }
    }

    static let formatters: [DateFormatter] = {
        ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss zzz", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd HH:mm:ss"].map {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = $0; return f
        }
    }()

    static func parseDate(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        for f in formatters { if let d = f.date(from: s) { return d } }
        return nil
    }
}
