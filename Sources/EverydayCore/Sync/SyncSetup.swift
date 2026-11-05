import Foundation

/// Quick setup: a one-time handoff of accounts, keys and settings to a newly paired device.
/// It only travels when the person showed a pairing code with "Include accounts and keys" on, the code is used
/// within 10 minutes, and only once. Same bundle format as windows/mobile/src/synchost.rs.
public enum SyncSetup {
    public static func export(prefs: Prefs = .shared) -> SyncJSON {
        var o: [String: SyncJSON] = [:]
        o["name"] = .string(prefs.string("userName"))
        o["city"] = .string(prefs.string(Prefs.Key.city))
        o["icsUrl"] = .string(prefs.string("icsUrl"))
        o["categories"] = .array(prefs.strings(Prefs.Key.categories).map { .string($0) })
        o["followedTopics"] = .array(prefs.strings(Prefs.Key.followedTopics).map { .string($0) })
        o["mutedTopics"] = .array(prefs.strings(Prefs.Key.mutedTopics).map { .string($0) })
        o["briefingInstructions"] = .string(prefs.string(Prefs.Key.briefingInstructions))
        o["briefingHour"] = .int(Int64(prefs.double(Prefs.Key.briefingHour, default: 7)))
        o["morningOn"] = .bool(prefs.bool(Prefs.Key.briefingNotify, default: false))
        o["aiProvider"] = .string(prefs.string(Prefs.Key.provider, default: "gemini"))
        var keys: [String: SyncJSON] = [:]
        for p in ProviderID.allCases { if let k = Keychain.get(KeychainAccount.aiKey(p.rawValue)), !k.isEmpty { keys[p.rawValue] = .string(k) } }
        o["aiKeys"] = .object(keys)
        o["accounts"] = .array(ImapAccounts.load(prefs).compactMap { a in
            guard let pw = Keychain.get(ImapBackend.passwordKey(a.email)), !pw.isEmpty else { return nil }
            return .object(["email": .string(a.email), "username": .string(a.username), "presetID": .string(a.presetID), "imapHost": .string(a.imapHost), "imapPort": .int(Int64(a.imapPort)),
                            "smtpHost": .string(a.smtpHost), "smtpPort": .int(Int64(a.smtpPort)), "smtpSecurity": .string(a.smtpSecurity.rawValue), "password": .string(pw)])
        })
        return .object(o)
    }

    /// Applies a bundle from another device. Returns a short description of what was set up.
    @discardableResult public static func apply(_ b: SyncJSON, prefs: Prefs = .shared) -> String {
        func strs(_ k: String) -> [String]? { if case .array(let a) = b[k] { return a.compactMap(\.string) }; return nil }
        if let n = b["name"].string, !n.isEmpty { prefs.set(n, "userName") }
        if let c = b["city"].string, !c.isEmpty { prefs.set(c, Prefs.Key.city) }
        if let u = b["icsUrl"].string, !u.isEmpty { prefs.set(u, "icsUrl") }
        for (k, key) in [("categories", Prefs.Key.categories), ("followedTopics", Prefs.Key.followedTopics), ("mutedTopics", Prefs.Key.mutedTopics)] { if let v = strs(k), !v.isEmpty { prefs.set(v, key) } }
        if let i = b["briefingInstructions"].string, !i.isEmpty { prefs.set(i, Prefs.Key.briefingInstructions) }
        if let h = b["briefingHour"].int { prefs.set(Double(h), Prefs.Key.briefingHour) }
        if case .bool(let on) = b["morningOn"] { prefs.set(on, Prefs.Key.briefingNotify) }
        var keys = 0
        if case .object(let k) = b["aiKeys"] { for (p, v) in k { if let s = v.string, !s.isEmpty, (try? Keychain.set(s, for: KeychainAccount.aiKey(p))) != nil { keys += 1 } } }
        if let p = b["aiProvider"].string, ProviderID(rawValue: p) != nil { prefs.set(p, Prefs.Key.provider) }
        var mails: [String] = []
        if case .array(let accts) = b["accounts"] {
            for a in accts {
                guard let email = a["email"].string, let pw = a["password"].string, let host = a["imapHost"].string, let smtp = a["smtpHost"].string else { continue }
                let sp = Int(a["smtpPort"].int ?? 465)
                let acct = ImapAccount(email: email, username: a["username"].string ?? email, presetID: a["presetID"].string ?? "custom", imapHost: host, imapPort: Int(a["imapPort"].int ?? 993),
                                       smtpHost: smtp, smtpPort: sp, smtpSecurity: MailPreset.Security(rawValue: a["smtpSecurity"].string ?? "") ?? (sp == 587 ? .starttls : .ssl))
                if (try? ImapBackend(prefs: prefs).save(account: acct, password: pw)) != nil { mails.append(email) }
            }
        }
        prefs.set(true, Prefs.Key.onboarded)
        var parts: [String] = []
        if !mails.isEmpty { parts.append(mails.joined(separator: ", ")) }
        if keys > 0 { parts.append("\(keys) AI key\(keys == 1 ? "" : "s")") }
        parts.append("your settings")
        return "Set up " + parts.joined(separator: ", ") + "."
    }
}
