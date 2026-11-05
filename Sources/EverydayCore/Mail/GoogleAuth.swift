import Foundation
import Network
import CryptoKit

public enum GoogleAuthError: Error, LocalizedError {
    case missingClient, cancelled, denied(String), exchange(String), noRefreshToken, timeout
    public var errorDescription: String? {
        switch self {
        case .missingClient: return "Add your Google OAuth client ID in Settings → Accounts first."
        case .cancelled: return "Sign-in was cancelled."
        case .denied(let s): return "Google refused the sign-in: \(s)"
        case .exchange(let s): return "Could not complete sign-in: \(s)"
        case .noRefreshToken: return "Google did not return a refresh token. Remove everyday. from myaccount.google.com/permissions and try again."
        case .timeout: return "Sign-in timed out."
        }
    }
}

/// Google OAuth for installed apps: PKCE + loopback redirect. Tokens live only in the Keychain.
public final class GoogleAuth: @unchecked Sendable {
    public static let scopes = ["https://www.googleapis.com/auth/gmail.modify", "https://www.googleapis.com/auth/gmail.compose"]
    private let prefs: Prefs
    private var cache: [String: (token: String, expires: Date)] = [:]
    private let lock = NSLock()

    public init(prefs: Prefs = .shared) { self.prefs = prefs }

    public var clientID: String {
        get { prefs.string(Prefs.Key.googleClientID) }
        set { prefs.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), Prefs.Key.googleClientID) }
    }
    public var clientSecret: String {
        get { Keychain.get(KeychainAccount.googleClientSecret) ?? "" }
        set { let v = newValue.trimmingCharacters(in: .whitespacesAndNewlines); if v.isEmpty { Keychain.delete(KeychainAccount.googleClientSecret) } else { try? Keychain.set(v, for: KeychainAccount.googleClientSecret) } }
    }
    public var accountEmail: String? {
        let e = prefs.string(Prefs.Key.googleEmail)
        return e.isEmpty ? nil : e
    }

    public func signOut() {
        if let e = accountEmail { Keychain.delete(KeychainAccount.googleRefreshToken(e)) }
        prefs.remove(Prefs.Key.googleEmail)
        lock.withLock { cache = [:] }
    }

    private static func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// `openURL` opens the consent page in the user's browser (provided by the app layer).
    public func signIn(openURL: @escaping @Sendable (URL) -> Void) async throws -> String {
        guard !clientID.isEmpty else { throw GoogleAuthError.missingClient }
        var rnd = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, rnd.count, &rnd)
        let verifier = Self.b64url(Data(rnd))
        let challenge = Self.b64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.b64url(Data(rnd.prefix(16)))

        let server = LoopbackServer()
        let port = try await server.start()
        let redirect = "http://127.0.0.1:\(port)"
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: redirect), .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scopes.joined(separator: " ")), .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent"),
        ]
        openURL(c.url!)
        let params = try await server.waitForCallback(timeout: 300)
        server.stop()
        if let err = params["error"] { throw GoogleAuthError.denied(err) }
        guard params["state"] == state, let code = params["code"] else { throw GoogleAuthError.exchange("state mismatch") }

        var body = ["code": code, "client_id": clientID, "code_verifier": verifier, "grant_type": "authorization_code", "redirect_uri": redirect]
        if !clientSecret.isEmpty { body["client_secret"] = clientSecret }
        let tok = try await Self.tokenRequest(body)
        guard let refresh = tok["refresh_token"] as? String else { throw GoogleAuthError.noRefreshToken }
        guard let access = tok["access_token"] as? String else { throw GoogleAuthError.exchange("no access token") }

        var req = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!)
        req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let email = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["emailAddress"] as? String else {
            throw GoogleAuthError.exchange("Gmail API refused the token. Check that the Gmail API is enabled for your Google Cloud project.")
        }
        try Keychain.set(refresh, for: KeychainAccount.googleRefreshToken(email))
        prefs.set(email, Prefs.Key.googleEmail)
        lock.withLock { cache[email] = (access, Date().addingTimeInterval((tok["expires_in"] as? Double ?? 3000) - 60)) }
        return email
    }

    public func accessToken() async throws -> String {
        guard let email = accountEmail else { throw GoogleAuthError.cancelled }
        if let c = lock.withLock({ cache[email] }), c.expires > Date() { return c.token }
        guard let refresh = Keychain.get(KeychainAccount.googleRefreshToken(email)) else { throw GoogleAuthError.noRefreshToken }
        var body = ["refresh_token": refresh, "client_id": clientID, "grant_type": "refresh_token"]
        if !clientSecret.isEmpty { body["client_secret"] = clientSecret }
        let tok = try await Self.tokenRequest(body)
        guard let access = tok["access_token"] as? String else { throw GoogleAuthError.exchange("no access token") }
        lock.withLock { cache[email] = (access, Date().addingTimeInterval((tok["expires_in"] as? Double ?? 3000) - 60)) }
        return access
    }

    private static func tokenRequest(_ body: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = body.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }.joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let d = (obj["error_description"] as? String) ?? (obj["error"] as? String) ?? "HTTP \(http.statusCode)"
            throw GoogleAuthError.exchange(d)
        }
        return obj
    }
}

final class LoopbackServer: @unchecked Sendable {
    private var listener: NWListener?
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var pending: Result<[String: String], Error>?
    private let lock = NSLock()

    func start() async throws -> UInt16 {
        let l = try NWListener(using: .tcp, on: .any)
        listener = l
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        final class Once: @unchecked Sendable { private let lock = NSLock(); private var done = false; func take() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true } }
        let once = Once()
        return try await withCheckedThrowingContinuation { cont in
            l.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.take() { cont.resume(returning: l.port?.rawValue ?? 0) }
                case .failed(let e): if once.take() { cont.resume(throwing: e) }
                default: break
                }
            }
            l.start(queue: .global())
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global())
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let req = String(data: data, encoding: .utf8), let line = req.components(separatedBy: "\r\n").first else { conn.cancel(); return }
            let parts = line.split(separator: " ")
            guard parts.count >= 2, let comps = URLComponents(string: "http://x" + parts[1]) else { conn.cancel(); return }
            guard comps.queryItems?.contains(where: { $0.name == "code" || $0.name == "error" }) == true else {
                conn.send(content: "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
                return
            }
            var params: [String: String] = [:]
            for q in comps.queryItems ?? [] { params[q.name] = q.value ?? "" }
            let html = "<html><head><meta charset='utf-8'><title>everyday.</title></head><body style='font-family:Georgia,serif;background:#1c1b19;color:#ece8df;display:flex;height:100vh;align-items:center;justify-content:center'><div><h1 style='font-weight:400'>You're connected.</h1><p>You can close this tab and return to everyday.</p></div></body></html>"
            let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
            self.deliver(.success(params))
        }
    }

    private func deliver(_ r: Result<[String: String], Error>) {
        lock.lock(); defer { lock.unlock() }
        if let c = continuation { continuation = nil; c.resume(with: r) } else if pending == nil { pending = r }
    }

    func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self?.deliver(.failure(GoogleAuthError.timeout))
        }
        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if let p = pending { pending = nil; lock.unlock(); cont.resume(with: p) } else { continuation = cont; lock.unlock() }
        }
    }

    func stop() { listener?.cancel(); listener = nil }
}
