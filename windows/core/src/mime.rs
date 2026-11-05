//! Reads a raw email into what the app needs: headers, plain-text body, attachment names, and the unsubscribe target.
use mail_parser::{HeaderValue, MessageParser, MimeHeaders};
use url::Url;

#[derive(Debug, Default, Clone, PartialEq)]
pub struct ParsedMail {
    pub subject: String, pub from_name: String, pub from_address: String, pub to: String,
    pub message_id: String, pub in_reply_to: String, pub references: Vec<String>,
    pub body: String, pub attachment_names: Vec<String>, pub list_unsubscribe: Option<String>,
    pub date: Option<i64>,
}

impl ParsedMail {
    pub fn has_attachments(&self) -> bool { !self.attachment_names.is_empty() }
    /// Stable conversation key: the root of References, else In-Reply-To, else the message's own id.
    pub fn thread_key(&self) -> String {
        if let Some(r) = self.references.first() { return r.clone(); }
        if !self.in_reply_to.is_empty() { return self.in_reply_to.clone(); }
        if !self.message_id.is_empty() { return self.message_id.clone(); }
        self.subject.to_lowercase()
    }
}

fn text_of(h: Option<&HeaderValue>) -> Vec<String> {
    match h { Some(HeaderValue::Text(t)) => vec![t.to_string()], Some(HeaderValue::TextList(l)) => l.iter().map(|t| t.to_string()).collect(), _ => vec![] }
}

pub fn parse(raw: &[u8]) -> ParsedMail {
    let Some(m) = MessageParser::default().parse(raw) else { return ParsedMail::default() };
    let mut p = ParsedMail::default();
    p.subject = m.subject().unwrap_or("").to_string();
    p.date = m.date().filter(|d| d.is_valid()).map(|d| d.to_timestamp());
    if let Some(a) = m.from().and_then(|f| f.first()) { p.from_name = a.name().unwrap_or("").to_string(); p.from_address = a.address().unwrap_or("").to_string(); }
    p.to = m.to().map(|t| t.iter().filter_map(|a| a.address()).collect::<Vec<_>>().join(", ")).unwrap_or_default();
    p.message_id = m.message_id().unwrap_or("").to_string();
    p.in_reply_to = text_of(Some(m.in_reply_to())).into_iter().next().unwrap_or_default();
    p.references = text_of(Some(m.references()));
    p.body = m.body_text(0).map(|b| b.to_string()).unwrap_or_default();
    p.attachment_names = m.attachments().filter_map(|a| a.attachment_name().map(String::from)).collect();
    p.list_unsubscribe = m.header_raw("List-Unsubscribe").map(|s| s.trim().to_string());
    p
}

/// Bytes of one attached file, by name.
pub fn attachment_data(raw: &[u8], name: &str) -> Option<Vec<u8>> {
    let m = MessageParser::default().parse(raw)?;
    m.attachments().find(|a| a.attachment_name() == Some(name)).map(|a| a.contents().to_vec())
}

/// Apps and scripts are never opened from an attachment.
pub fn is_safe_to_preview(name: &str) -> bool {
    const UNSAFE: &[&str] = &["app", "command", "sh", "exe", "bat", "cmd", "com", "scr", "pkg", "dmg", "jar", "js", "vbs", "ps1", "msi", "dylib", "terminal", "workflow", "action", "scpt", "pif", "lnk", "iso", "apk", "ipa", "msix", "reg", "hta", "wsf"];
    let ext = name.rsplit_once('.').map(|(_, e)| e.to_lowercase()).unwrap_or_default();
    !UNSAFE.contains(&ext.as_str())
}

/// A file name that cannot escape the cache folder.
pub fn safe_file_name(name: &str) -> String {
    let cleaned: String = name.chars().map(|c| if c == '/' || c == '\\' || c == ':' || (c as u32) < 32 { '_' } else { c }).collect();
    let trimmed = cleaned.trim_matches(|c| c == '.' || c == ' ');
    if trimmed.is_empty() { "attachment".into() } else { trimmed.chars().take(120).collect() }
}

#[derive(Debug, Default, PartialEq)]
pub struct UnsubscribeTarget { pub web: Option<Url>, pub mailto: Option<String> }
impl UnsubscribeTarget {
    pub fn host(&self) -> String {
        self.web.as_ref().and_then(|u| u.host_str().map(String::from))
            .or_else(|| self.mailto.as_ref().and_then(|m| m.split('@').last().map(String::from)))
            .unwrap_or_else(|| "the sender".into())
    }
}
/// Parses a List-Unsubscribe header. Plain http links are ignored; nothing is opened until the user approves.
pub fn parse_unsubscribe(header: Option<&str>) -> Option<UnsubscribeTarget> {
    let h = header?; let mut t = UnsubscribeTarget::default();
    for part in h.split('<').skip(1) {
        let item = part.split('>').next().unwrap_or("").trim();
        if item.to_lowercase().starts_with("https://") && t.web.is_none() { t.web = Url::parse(item).ok(); }
        else if item.to_lowercase().starts_with("mailto:") && t.mailto.is_none() { t.mailto = Some(item[7..].to_string()); }
    }
    if t.web.is_none() && t.mailto.is_none() { None } else { Some(t) }
}

#[cfg(test)]
mod tests {
    use super::*;
    const RAW: &str = "From: Oscar Fox <oscar@acme.com>\r\nTo: me@example.com\r\nSubject: Files\r\nMessage-ID: <m2@x>\r\nIn-Reply-To: <a@x>\r\nReferences: <a@x> <b@x>\r\nList-Unsubscribe: <mailto:unsub@brew.com?subject=unsubscribe>, <https://brew.com/u?x=1>\r\nContent-Type: multipart/mixed; boundary=\"BB\"\r\n\r\n--BB\r\nContent-Type: text/plain\r\n\r\nSee attached.\r\n--BB\r\nContent-Type: application/pdf; name=\"Lease.pdf\"\r\nContent-Disposition: attachment; filename=\"Lease.pdf\"\r\nContent-Transfer-Encoding: base64\r\n\r\nSGVsbG8gUERG\r\n--BB--\r\n";
    #[test] fn headers_body_and_threading() {
        let p = parse(RAW.as_bytes());
        assert_eq!((p.subject.as_str(), p.from_name.as_str(), p.from_address.as_str()), ("Files", "Oscar Fox", "oscar@acme.com"));
        assert!(p.body.contains("See attached.")); assert_eq!(p.thread_key(), "a@x");
    }
    #[test] fn attachments_are_listed_and_decoded_on_demand() {
        let p = parse(RAW.as_bytes());
        assert_eq!(p.attachment_names, ["Lease.pdf"]); assert!(p.has_attachments());
        assert_eq!(attachment_data(RAW.as_bytes(), "Lease.pdf").unwrap(), b"Hello PDF");
    }
    #[test] fn apps_and_scripts_are_never_opened() {
        assert!(!is_safe_to_preview("Invoice.app") && !is_safe_to_preview("run.COMMAND") && !is_safe_to_preview("x.sh") && !is_safe_to_preview("setup.exe"));
        assert!(is_safe_to_preview("Lease.pdf") && is_safe_to_preview("photo.jpeg"));
    }
    #[test] fn file_names_cannot_escape_the_cache() { assert!(!safe_file_name("../../etc/passwd").contains('/')); assert_eq!(safe_file_name("..."), "attachment"); }
    #[test] fn unsubscribe_header() {
        let u = parse_unsubscribe(Some("<mailto:unsub@brew.com?subject=unsubscribe>, <https://brew.com/u?x=1>")).unwrap();
        assert_eq!(u.web.unwrap().as_str(), "https://brew.com/u?x=1"); assert_eq!(u.mailto.as_deref(), Some("unsub@brew.com?subject=unsubscribe"));
        assert!(parse_unsubscribe(Some("<http://evil.example/u>")).is_none() && parse_unsubscribe(None).is_none());
    }
    #[test] fn unsubscribe_header_survives_parsing() { assert!(parse(RAW.as_bytes()).list_unsubscribe.unwrap().contains("brew.com")); }
}
