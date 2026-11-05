import Foundation

public struct MailAttachment: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var type: String
    public var size: Int
    public var id: String { name }
    public init(name: String, type: String, size: Int) { self.name = name; self.type = type; self.size = size }
}

public struct ParsedMail: Sendable {
    public var subject = ""
    public var fromName = ""
    public var fromAddress = ""
    public var to = ""
    public var date: Date?
    public var messageId = ""
    public var inReplyTo = ""
    public var references: [String] = []
    public var body = ""
    public var hasAttachments = false
    public var listUnsubscribe: String?
    public var attachmentNames: [String] = []

    /// Stable conversation key: the root of References, else In-Reply-To, else the message's own id.
    public var threadKey: String {
        let k = references.first ?? (inReplyTo.isEmpty ? messageId : inReplyTo)
        return k.isEmpty ? subject.lowercased() : k
    }
}

public enum MIME {
    // MARK: Entry

    public static func parse(_ raw: Data) -> ParsedMail {
        let (headers, body) = splitHeaders(raw)
        var m = ParsedMail()
        m.subject = decodeWords(headers["subject"] ?? "")
        let (n, a) = parseAddress(decodeWords(headers["from"] ?? ""))
        m.fromName = n; m.fromAddress = a
        m.to = decodeWords(headers["to"] ?? "")
        if var d = headers["date"] {
            if let p = d.range(of: #"\s*\(.*\)"#, options: .regularExpression) { d.removeSubrange(p) }
            m.date = FeedParser.parseDate(d.trimmingCharacters(in: .whitespaces))
        }
        m.messageId = (headers["message-id"] ?? "").trimmingCharacters(in: .whitespaces)
        m.inReplyTo = firstId(headers["in-reply-to"] ?? "")
        m.references = ids(headers["references"] ?? "")
        m.listUnsubscribe = headers["list-unsubscribe"]
        var plain = "", html = "", attach = false
        walk(headers: headers, body: body, plain: &plain, html: &html, attach: &attach, depth: 0)
        if attach { m.attachmentNames = attachments(headers: headers, body: body, includeData: false).map { $0.info.name } }
        m.body = plain.isEmpty ? HTMLText.plain(html) : plain
        m.hasAttachments = attach
        return m
    }

    // MARK: Structure

    static func splitHeaders(_ data: Data) -> ([String: String], Data) {
        let crlf = Data([13, 10, 13, 10]), lf = Data([10, 10])
        var headerData = data, bodyData = Data()
        if let r = data.range(of: crlf) { headerData = data.subdata(in: data.startIndex..<r.lowerBound); bodyData = data.subdata(in: r.upperBound..<data.endIndex) }
        else if let r = data.range(of: lf) { headerData = data.subdata(in: data.startIndex..<r.lowerBound); bodyData = data.subdata(in: r.upperBound..<data.endIndex) }
        let text = String(decoding: headerData, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        var out: [String: String] = [:]
        var lastKey: String?
        for line in text.components(separatedBy: "\n") {
            if line.first == " " || line.first == "\t" { if let k = lastKey { out[k, default: ""] += " " + line.trimmingCharacters(in: .whitespaces) }; continue }
            guard let c = line.firstIndex(of: ":") else { continue }
            let key = line[..<c].lowercased()
            if out[key] == nil { out[key] = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces) }
            lastKey = out[key] != nil ? key : lastKey
        }
        return (out, bodyData)
    }

    static func params(_ header: String) -> (value: String, params: [String: String]) {
        let parts = splitOutsideQuotes(header, on: ";")
        var p: [String: String] = [:]
        for s in parts.dropFirst() {
            guard let eq = s.firstIndex(of: "=") else { continue }
            let k = s[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var v = s[s.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 { v = String(v.dropFirst().dropLast()) }
            p[k] = v
        }
        return (parts.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? "", p)
    }

    static func splitOutsideQuotes(_ s: String, on sep: Character) -> [String] {
        var out: [String] = [], cur = "", q = false
        for ch in s { if ch == "\"" { q.toggle() }; if ch == sep && !q { out.append(cur); cur = "" } else { cur.append(ch) } }
        out.append(cur)
        return out
    }

    static func walk(headers: [String: String], body: Data, plain: inout String, html: inout String, attach: inout Bool, depth: Int) {
        guard depth < 8 else { return }
        let (type, ct) = params(headers["content-type"] ?? "text/plain")
        let (disp, dp) = params(headers["content-disposition"] ?? "")
        if type.hasPrefix("multipart/"), let boundary = ct["boundary"] {
            for part in split(body, boundary: boundary) {
                let (h, b) = splitHeaders(part)
                walk(headers: h, body: b, plain: &plain, html: &html, attach: &attach, depth: depth + 1)
            }
            return
        }
        if type == "message/rfc822" { let (h, b) = splitHeaders(decodeTransfer(body, headers["content-transfer-encoding"])); walk(headers: h, body: b, plain: &plain, html: &html, attach: &attach, depth: depth + 1); return }
        let isAttachment = disp == "attachment" || dp["filename"] != nil || ct["name"] != nil
        if isAttachment && !(type == "text/plain" && disp != "attachment") { attach = true; return }
        guard type == "text/plain" || type == "text/html" else { if !type.isEmpty { attach = true }; return }
        let bytes = decodeTransfer(body, headers["content-transfer-encoding"])
        let text = string(bytes, charset: ct["charset"])
        if type == "text/plain" { plain += (plain.isEmpty ? "" : "\n\n") + text } else { html += text }
    }

    /// Every file attached to a message. `includeData: false` lists names only (cheap, used while syncing).
    public static func attachments(in raw: Data, includeData: Bool) -> [(info: MailAttachment, data: Data?)] {
        let (h, b) = splitHeaders(raw)
        return attachments(headers: h, body: b, includeData: includeData)
    }

    static func attachments(headers: [String: String], body: Data, includeData: Bool, depth: Int = 0) -> [(info: MailAttachment, data: Data?)] {
        guard depth < 8 else { return [] }
        let (type, ct) = params(headers["content-type"] ?? "text/plain")
        let (disp, dp) = params(headers["content-disposition"] ?? "")
        if type.hasPrefix("multipart/"), let boundary = ct["boundary"] {
            return split(body, boundary: boundary).flatMap { part -> [(info: MailAttachment, data: Data?)] in
                let (h, b) = splitHeaders(part); return attachments(headers: h, body: b, includeData: includeData, depth: depth + 1)
            }
        }
        if type == "message/rfc822" { return [] }
        let raw = dp["filename"] ?? ct["name"]
        guard let raw, !raw.isEmpty, !(type == "text/plain" && disp != "attachment" && raw.isEmpty) else { return [] }
        let name = decodeWords(raw)
        let data = includeData ? decodeTransfer(body, headers["content-transfer-encoding"]) : nil
        return [(MailAttachment(name: name, type: type, size: data?.count ?? body.count * 3 / 4), data)]
    }

    static func split(_ body: Data, boundary: String) -> [Data] {
        let delim = Data("--\(boundary)".utf8)
        var parts: [Data] = []
        var idx = body.startIndex
        var starts: [Int] = []
        while let r = body.range(of: delim, in: idx..<body.endIndex) { starts.append(r.lowerBound); idx = r.upperBound }
        for (i, s) in starts.enumerated() {
            var start = s + delim.count
            if body.count > start + 1, body[start] == 45, body[start + 1] == 45 { break }          // closing --
            while start < body.count, body[start] == 13 || body[start] == 10 { start += 1; if body[start - 1] == 10 { break } }
            var end = i + 1 < starts.count ? starts[i + 1] : body.count
            while end > start, body[end - 1] == 10 || body[end - 1] == 13 { end -= 1 }
            if end > start { parts.append(body.subdata(in: start..<end)) }
        }
        return parts
    }

    // MARK: Decoding

    static func decodeTransfer(_ data: Data, _ encoding: String?) -> Data {
        switch (encoding ?? "7bit").lowercased().trimmingCharacters(in: .whitespaces) {
        case "base64":
            let s = String(decoding: data, as: UTF8.self).components(separatedBy: .whitespacesAndNewlines).joined()
            return Data(base64Encoded: s, options: .ignoreUnknownCharacters) ?? data
        case "quoted-printable": return decodeQuotedPrintable(data)
        default: return data
        }
    }

    static func decodeQuotedPrintable(_ data: Data) -> Data {
        var out = Data(); out.reserveCapacity(data.count)
        let b = [UInt8](data)
        var i = 0
        func hex(_ c: UInt8) -> UInt8? { switch c { case 48...57: return c - 48; case 65...70: return c - 55; case 97...102: return c - 87; default: return nil } }
        while i < b.count {
            if b[i] == 61 {  // '='
                if i + 1 < b.count, b[i + 1] == 13 { i += (i + 2 < b.count && b[i + 2] == 10) ? 3 : 2; continue }
                if i + 1 < b.count, b[i + 1] == 10 { i += 2; continue }
                if i + 2 < b.count, let h = hex(b[i + 1]), let l = hex(b[i + 2]) { out.append(h << 4 | l); i += 3; continue }
            }
            out.append(b[i]); i += 1
        }
        return out
    }

    static func encoding(_ charset: String?) -> String.Encoding {
        guard let c = charset?.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).lowercased(), !c.isEmpty else { return .utf8 }
        if c == "utf-8" || c == "utf8" { return .utf8 }
        if c == "us-ascii" { return .ascii }
        if c == "iso-8859-1" || c == "latin1" { return .isoLatin1 }
        if c == "windows-1252" || c == "cp1252" { return .windowsCP1252 }
        let cf = CFStringConvertIANACharSetNameToEncoding(c as CFString)
        if cf != kCFStringEncodingInvalidId { return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf)) }
        return .utf8
    }

    static func string(_ d: Data, charset: String?) -> String {
        String(data: d, encoding: encoding(charset)) ?? String(data: d, encoding: .isoLatin1) ?? String(decoding: d, as: UTF8.self)
    }

    /// RFC 2047 encoded words in headers: =?charset?B|Q?text?=
    public static func decodeWords(_ s: String) -> String {
        guard s.contains("=?") else { return s }
        let re = try! NSRegularExpression(pattern: #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#)
        let ns = s as NSString
        var out = "", last = 0
        var prevWasWord = false
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let gap = ns.substring(with: NSRange(location: last, length: m.range.location - last))
            if !(prevWasWord && gap.trimmingCharacters(in: .whitespaces).isEmpty) { out += gap }
            let charset = ns.substring(with: m.range(at: 1)), kind = ns.substring(with: m.range(at: 2)).lowercased(), text = ns.substring(with: m.range(at: 3))
            var bytes = Data()
            if kind == "b" { bytes = Data(base64Encoded: text) ?? Data() }
            else { bytes = decodeQuotedPrintable(Data(text.replacingOccurrences(of: "_", with: " ").utf8)) }
            out += string(bytes, charset: charset)
            last = m.range.location + m.range.length
            prevWasWord = true
        }
        out += ns.substring(from: last)
        return out
    }

    // MARK: Addresses and ids

    public static func parseAddress(_ s: String) -> (name: String, address: String) {
        if let l = s.lastIndex(of: "<"), let r = s.lastIndex(of: ">"), l < r {
            let addr = String(s[s.index(after: l)..<r]).trimmingCharacters(in: .whitespaces)
            var name = String(s[..<l]).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if name.isEmpty { name = addr }
            return (name, addr)
        }
        let t = s.trimmingCharacters(in: .whitespaces)
        return (t, t)
    }

    static func ids(_ s: String) -> [String] {
        let re = try! NSRegularExpression(pattern: "<[^>]+>")
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }
    static func firstId(_ s: String) -> String { ids(s).first ?? "" }
}
