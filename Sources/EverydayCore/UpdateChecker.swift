import Foundation

/// Tells the user when a newer version exists. It reads one small public JSON file and sends nothing about the user;
/// it never downloads or installs anything, it only points to the download page.
public enum UpdateChecker {
    public struct Release: Equatable, Sendable { public var version: String; public var url: URL; public var notes: String }

    public static let defaultFeed = "https://everyday.mandrusia.tech/version.json"

    /// True when `a` is a newer dotted version than `b` (1.10.0 > 1.9.2; missing parts count as 0).
    public static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Parses `{ "version": "1.2.0", "url": "https://…", "notes": "…" }`. Only https links on the expected site are accepted.
    public static func parse(_ data: Data, allowedHost: String = "everyday.mandrusia.tech") -> Release? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let v = o["version"] as? String, !v.isEmpty,
              let u = (o["url"] as? String).flatMap(URL.init(string:)), u.scheme == "https", let host = u.host, host == allowedHost || host.hasSuffix("." + allowedHost) || host == "github.com" else { return nil }
        return Release(version: v, url: u, notes: String((o["notes"] as? String ?? "").prefix(300)))
    }

    public static func latest(feed: String = defaultFeed, allowedHost: String = "everyday.mandrusia.tech") async -> Release? {
        guard let url = URL(string: feed), url.scheme == "https" || url.host == "localhost" else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("everyday-update-check", forHTTPHeaderField: "User-Agent")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(data, allowedHost: allowedHost)
    }
}
