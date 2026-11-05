//! Update notice: compares versions and validates the one public JSON file the app reads.
use url::Url;

#[derive(Debug, PartialEq, Clone)]
pub struct Release { pub version: String, pub url: Url, pub notes: String }

/// True when `a` is a newer dotted version than `b` (1.10.0 > 1.9.2; missing parts count as 0).
pub fn is_newer(a: &str, b: &str) -> bool {
    fn parts(s: &str) -> Vec<u64> {
        s.trim_matches(|c| c == 'v' || c == 'V' || c == ' ').split('.')
            .map(|p| p.chars().take_while(|c| c.is_ascii_digit()).collect::<String>().parse().unwrap_or(0)).collect()
    }
    let (x, y) = (parts(a), parts(b));
    for i in 0..x.len().max(y.len()) {
        let (l, r) = (*x.get(i).unwrap_or(&0), *y.get(i).unwrap_or(&0));
        if l != r { return l > r; }
    }
    false
}

/// Parses `{ "version": "1.2.0", "url": "https://…", "notes": "…" }`. Only https links on the expected site (or github.com) are accepted.
pub fn parse(data: &str, allowed_host: &str) -> Option<Release> {
    let v: serde_json::Value = serde_json::from_str(data).ok()?;
    let version = v.get("version")?.as_str()?.to_string();
    if version.is_empty() { return None; }
    let url = Url::parse(v.get("url")?.as_str()?).ok()?;
    let host = url.host_str()?.to_string();
    if url.scheme() != "https" || !(host == allowed_host || host.ends_with(&format!(".{allowed_host}")) || host == "github.com") { return None; }
    let notes: String = v.get("notes").and_then(|n| n.as_str()).unwrap_or("").chars().take(300).collect();
    Some(Release { version, url, notes })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn version_compare() {
        assert!(is_newer("1.10.0", "1.9.2")); assert!(!is_newer("1.2.0", "1.2"));
        assert!(is_newer("v2", "1.9.9")); assert!(!is_newer("0.1.0", "0.1.0"));
    }
    #[test] fn feed_parsing() {
        let ok = r#"{"version":"0.2.0","url":"https://everyday.mandrusia.tech/download","notes":"Snooze, VIP"}"#;
        let r = parse(ok, "everyday.mandrusia.tech").unwrap();
        assert_eq!(r.version, "0.2.0"); assert_eq!(r.notes, "Snooze, VIP");
        assert!(parse(r#"{"version":"9","url":"http://everyday.mandrusia.tech/x"}"#, "everyday.mandrusia.tech").is_none());
        assert!(parse(r#"{"version":"9","url":"https://evil.example/x"}"#, "everyday.mandrusia.tech").is_none());
        assert!(parse("nope", "everyday.mandrusia.tech").is_none());
    }
}
