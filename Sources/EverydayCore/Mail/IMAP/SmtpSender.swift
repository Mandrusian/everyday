import Foundation

/// Sends one approved message over SMTP using the system curl (handles implicit TLS and STARTTLS).
/// The password goes through a private temporary config file, never on the command line.
public enum SmtpSender {
    /// Test hook: lets the checks talk to a scripted server on 127.0.0.1 without TLS. Ignored for every other host.
    nonisolated(unsafe) public static var allowLocalPlaintext = false
    public static func send(account: ImapAccount, password: String, from: String, to: [String], message: Data) async throws {
        guard !to.isEmpty else { throw ImapError.unsupported("No recipient.") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("everyday-smtp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let msgFile = dir.appendingPathComponent("message.eml")
        let cfgFile = dir.appendingPathComponent("curl.cfg")
        try message.write(to: msgFile, options: .atomic)
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        try "user = \"\(esc(account.username)):\(esc(password))\"\n".write(to: cfgFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cfgFile.path)

        let localTest = allowLocalPlaintext && account.smtpHost == "127.0.0.1"
        let scheme = localTest ? "smtp" : (account.smtpSecurity == .ssl ? "smtps" : "smtp")
        var args = ["-sS", "--max-time", "60", "--url", "\(scheme)://\(account.smtpHost):\(account.smtpPort)",
                    "--mail-from", from, "--upload-file", msgFile.path, "--config", cfgFile.path]
        if account.smtpSecurity == .starttls && !localTest { args += ["--ssl-reqd"] }
        for r in to { args += ["--mail-rcpt", r] }

        let (code, err) = try await run("/usr/bin/curl", args)
        guard code == 0 else {
            let e = err.trimmingCharacters(in: .whitespacesAndNewlines)
            if e.contains("535") || e.lowercased().contains("auth") { throw ImapError.auth("The server refused the password when sending. \(e)") }
            throw ImapError.command("SMTP", e.isEmpty ? "curl exit \(code)" : e)
        }
    }

    static func run(_ exe: String, _ args: [String]) async throws -> (Int32, String) {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            let errPipe = Pipe(), outPipe = Pipe()
            p.standardError = errPipe; p.standardOutput = outPipe
            p.terminationHandler = { proc in
                let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                cont.resume(returning: (proc.terminationStatus, err))
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }

    /// "Name <a@b.c>" → "a@b.c"
    public static func bareAddress(_ s: String) -> String {
        if let l = s.lastIndex(of: "<"), let r = s.lastIndex(of: ">"), l < r { return String(s[s.index(after: l)..<r]) }
        return s.trimmingCharacters(in: .whitespaces)
    }
}
