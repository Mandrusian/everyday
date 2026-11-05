import Foundation
import CryptoKit

public struct SyncBatch: Sendable {
    public var upserts: [EmailMessage]
    public var removedIDs: [String]
    public var state: String?
    public init(upserts: [EmailMessage], removedIDs: [String], state: String?) { self.upserts = upserts; self.removedIDs = removedIDs; self.state = state }
}

/// A source of mail. The app only ever talks to this protocol, so Gmail API and IMAP are interchangeable.
public protocol MailBackend: Sendable {
    var isConnected: Bool { get }
    var accountEmail: String? { get }
    func sync(days: Int, known: [EmailMessage], state: String?, progress: (@Sendable (String) -> Void)?) async throws -> SyncBatch
    func archive(_ messages: [EmailMessage]) async throws
    func trash(_ messages: [EmailMessage]) async throws
    func markRead(_ messages: [EmailMessage]) async throws
    func saveDraft(replyingTo: EmailMessage, body: String) async throws
    func sendReply(replyingTo: EmailMessage, body: String) async throws
    func attachmentData(_ message: EmailMessage, name: String) async throws -> Data
}

public extension MailBackend {
    func attachmentData(_ message: EmailMessage, name: String) async throws -> Data { throw MailAttachmentError.unsupported }
}

public enum MailAttachmentError: LocalizedError {
    case unsupported, unsafe(String)
    public var errorDescription: String? { switch self { case .unsupported: return "This account can't download attachments yet."; case .unsafe(let n): return "“\(n)” is an app or script, so everyday. won't open it. Save it from your mail provider if you trust it." } }
}

public enum MailBackendKind: String, Sendable { case gmailAPI = "gmail", imap = "imap" }

// MARK: Provider presets

public struct MailPreset: Identifiable, Hashable, Sendable {
    public enum Security: String, Codable, Sendable { case ssl, starttls }
    public var id: String
    public var name: String
    public var imapHost: String
    public var imapPort: Int
    public var smtpHost: String
    public var smtpPort: Int
    public var smtpSecurity: Security
    public var appPasswordURL: String?
    public var steps: [String]
    public var note: String?
    public var supported: Bool = true

    public static let all: [MailPreset] = [
        MailPreset(id: "gmail", name: "Gmail", imapHost: "imap.gmail.com", imapPort: 993, smtpHost: "smtp.gmail.com", smtpPort: 465, smtpSecurity: .ssl,
                   appPasswordURL: "https://myaccount.google.com/apppasswords",
                   steps: ["Turn on 2-Step Verification for your Google account (if it is not already on).", "Open the app passwords page, name it “everyday”, and press Create.", "Copy the 16-character password and paste it below."],
                   note: "Work or school Google accounts may not allow app passwords."),
        MailPreset(id: "icloud", name: "iCloud Mail", imapHost: "imap.mail.me.com", imapPort: 993, smtpHost: "smtp.mail.me.com", smtpPort: 587, smtpSecurity: .starttls,
                   appPasswordURL: "https://account.apple.com/account/manage/section/security",
                   steps: ["Sign in at account.apple.com and open Sign-In and Security.", "Choose App-Specific Passwords and create one named “everyday”.", "Paste it below. Use your full iCloud address."]),
        MailPreset(id: "fastmail", name: "Fastmail", imapHost: "imap.fastmail.com", imapPort: 993, smtpHost: "smtp.fastmail.com", smtpPort: 465, smtpSecurity: .ssl,
                   appPasswordURL: "https://app.fastmail.com/settings/security/devicekeys/new",
                   steps: ["Open Settings → Privacy & Security → Integrations → New app password.", "Choose “Mail (IMAP/POP/SMTP)” and create it.", "Paste it below."]),
        MailPreset(id: "yahoo", name: "Yahoo Mail", imapHost: "imap.mail.yahoo.com", imapPort: 993, smtpHost: "smtp.mail.yahoo.com", smtpPort: 465, smtpSecurity: .ssl,
                   appPasswordURL: "https://login.yahoo.com/account/security/app-passwords",
                   steps: ["Open Account Security → Generate app password.", "Name it “everyday” and copy the password.", "Paste it below."]),
        MailPreset(id: "outlook", name: "Outlook / Hotmail", imapHost: "outlook.office365.com", imapPort: 993, smtpHost: "smtp-mail.outlook.com", smtpPort: 587, smtpSecurity: .starttls,
                   appPasswordURL: nil, steps: [], note: "Microsoft no longer allows app passwords for IMAP on most accounts, so Outlook is not supported yet.", supported: false),
        MailPreset(id: "custom", name: "Other (IMAP)", imapHost: "", imapPort: 993, smtpHost: "", smtpPort: 465, smtpSecurity: .ssl, appPasswordURL: nil,
                   steps: ["Find your provider's IMAP and SMTP server names in its help pages.", "Use an app password if your provider offers one."]),
    ]

    public static func guess(email: String) -> MailPreset? {
        let d = email.split(separator: "@").last.map { $0.lowercased() } ?? ""
        switch d {
        case "gmail.com", "googlemail.com": return all.first { $0.id == "gmail" }
        case "icloud.com", "me.com", "mac.com": return all.first { $0.id == "icloud" }
        case "fastmail.com", "fastmail.fm": return all.first { $0.id == "fastmail" }
        case "yahoo.com", "yahoo.com.au", "ymail.com": return all.first { $0.id == "yahoo" }
        case "outlook.com", "hotmail.com", "live.com", "outlook.com.au": return all.first { $0.id == "outlook" }
        default: return nil
        }
    }
}

public struct ImapAccount: Codable, Hashable, Sendable {
    public var email: String
    public var username: String
    public var presetID: String
    public var imapHost: String
    public var imapPort: Int
    public var smtpHost: String
    public var smtpPort: Int
    public var smtpSecurity: MailPreset.Security
    public init(email: String, username: String, presetID: String, imapHost: String, imapPort: Int, smtpHost: String, smtpPort: Int, smtpSecurity: MailPreset.Security) {
        self.email = email; self.username = username; self.presetID = presetID; self.imapHost = imapHost; self.imapPort = imapPort
        self.smtpHost = smtpHost; self.smtpPort = smtpPort; self.smtpSecurity = smtpSecurity
    }
}

// MARK: Composing messages (used for drafts and replies)

public enum MailComposer {
    static func encodeHeader(_ s: String) -> String {
        s.allSatisfy(\.isASCII) ? s : "=?UTF-8?B?\(Data(s.utf8).base64EncodedString())?="
    }

    public static func build(from: String, to: String, subject: String, body: String, inReplyTo: String, domain: String) -> Data {
        var h = ["From: \(from)", "To: \(to)", "Subject: \(encodeHeader(subject))", "Date: \(rfc2822(Date()))",
                 "Message-ID: <\(UUID().uuidString.lowercased())@\(domain)>", "MIME-Version: 1.0"]
        if !inReplyTo.isEmpty { h += ["In-Reply-To: \(inReplyTo)", "References: \(inReplyTo)"] }
        h += ["Content-Type: text/plain; charset=utf-8", "Content-Transfer-Encoding: base64"]
        let b64 = Data(body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n").utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        return Data((h.joined(separator: "\r\n") + "\r\n\r\n" + b64 + "\r\n").utf8)
    }

    static func rfc2822(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"; return f.string(from: d)
    }

    public static func replyRecipient(_ m: EmailMessage, me: String) -> String {
        if m.fromAddress.lowercased() == me.lowercased() { return m.to }
        return m.fromName.contains(",") || m.fromName.contains("\"") ? "\"\(m.fromName.replacingOccurrences(of: "\"", with: ""))\" <\(m.fromAddress)>" : "\(m.fromName) <\(m.fromAddress)>"
    }

    public static func replySubject(_ s: String) -> String { s.lowercased().hasPrefix("re:") ? s : "Re: " + s }
}

enum Hashing {
    static func short(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined() }
}
