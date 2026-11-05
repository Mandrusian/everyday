//! SMTP sending (EHLO, AUTH PLAIN, MAIL FROM, RCPT TO, DATA) and the reply message composer. Sending only ever happens from a button the user pressed.
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use std::io::{BufRead, BufReader, Read, Write};

#[derive(Debug, Clone, PartialEq)]
pub enum SmtpError { Auth(String), Rejected(String), Io(String) }
impl std::fmt::Display for SmtpError { fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result { match self { SmtpError::Auth(m) | SmtpError::Rejected(m) | SmtpError::Io(m) => write!(f, "{m}") } } }
impl From<std::io::Error> for SmtpError { fn from(e: std::io::Error) -> Self { SmtpError::Io(format!("Connection problem: {e}")) } }

fn reply<S: Read + Write>(r: &mut BufReader<S>) -> Result<(u16, String), SmtpError> {
    let mut text = String::new();
    loop {
        let mut line = String::new(); if r.read_line(&mut line)? == 0 { return Err(SmtpError::Io("The server closed the connection.".into())); }
        let line = line.trim_end().to_string(); text.push_str(&line); text.push('\n');
        let code = line.get(..3).and_then(|s| s.parse::<u16>().ok())
            .ok_or_else(|| SmtpError::Io("The mail server returned an invalid SMTP response.".into()))?;
        if line.len() < 4 || line.as_bytes()[3] != b'-' { return Ok((code, text)); }
    }
}

fn cmd<S: Read + Write>(r: &mut BufReader<S>, line: &str, ok: &[u16]) -> Result<String, SmtpError> {
    r.get_mut().write_all(format!("{line}\r\n").as_bytes())?; r.get_mut().flush()?;
    let (code, text) = reply(r)?;
    if ok.contains(&code) { Ok(text) } else if code == 535 || code == 534 { Err(SmtpError::Auth(format!("The server refused the password when sending. {}", text.trim()))) } else { Err(SmtpError::Rejected(format!("{} ({code})", text.trim()))) }
}

/// Sends one message over an already-secured stream. `password` may be empty for servers without auth (tests).
pub fn send<S: Read + Write>(stream: S, user: &str, password: &str, from: &str, to: &[String], message: &[u8]) -> Result<(), SmtpError> {
    if to.is_empty() { return Err(SmtpError::Rejected("No recipient.".into())); }
    let mut r = BufReader::new(stream);
    let (code, _) = reply(&mut r)?; if code != 220 { return Err(SmtpError::Io("The mail server did not greet us.".into())); }
    session(r, user, password, from, to, message)
}

/// Same, for a stream whose greeting was already read (after STARTTLS).
pub fn send_after_greeting<S: Read + Write>(stream: S, user: &str, password: &str, from: &str, to: &[String], message: &[u8]) -> Result<(), SmtpError> {
    if to.is_empty() { return Err(SmtpError::Rejected("No recipient.".into())); }
    session(BufReader::new(stream), user, password, from, to, message)
}

fn session<S: Read + Write>(mut r: BufReader<S>, user: &str, password: &str, from: &str, to: &[String], message: &[u8]) -> Result<(), SmtpError> {
    // Envelope values are commands, not display headers. Never allow a supplied address to add a command.
    if std::iter::once(from).chain(to.iter().map(String::as_str)).any(|address|
        address.is_empty() || !address.contains('@') || address.chars().any(|c| c.is_control() || c == '<' || c == '>')) {
        return Err(SmtpError::Rejected("The sender or recipient address is invalid.".into()));
    }
    let ehlo = cmd(&mut r, "EHLO everyday.local", &[250])?;
    if !password.is_empty() && ehlo.to_uppercase().contains("AUTH") {
        let token = B64.encode(format!("\0{user}\0{password}"));
        cmd(&mut r, &format!("AUTH PLAIN {token}"), &[235])?;
    }
    cmd(&mut r, &format!("MAIL FROM:<{from}>"), &[250])?;
    for t in to { cmd(&mut r, &format!("RCPT TO:<{t}>"), &[250, 251])?; }
    cmd(&mut r, "DATA", &[354])?;
    let mut body = Vec::new();
    for line in message.split(|b| *b == b'\n') {    // dot-stuffing and CRLF line ends
        let line = line.strip_suffix(b"\r").unwrap_or(line);
        if line.first() == Some(&b'.') { body.push(b'.'); }
        body.extend_from_slice(line); body.extend_from_slice(b"\r\n");
    }
    body.extend_from_slice(b".\r\n");
    r.get_mut().write_all(&body)?; r.get_mut().flush()?;
    let (code, text) = reply(&mut r)?; if code != 250 { return Err(SmtpError::Rejected(format!("{} ({code})", text.trim()))); }
    let _ = cmd(&mut r, "QUIT", &[221]);
    Ok(())
}

pub struct ReplyTo<'a> { pub from_name: &'a str, pub from_address: &'a str, pub subject: &'a str, pub message_id: &'a str, pub references: &'a [String] }

/// "Name <a@b.c>" to "a@b.c".
pub fn bare_address(s: &str) -> String { match (s.rfind('<'), s.rfind('>')) { (Some(l), Some(r)) if l < r => s[l + 1..r].to_string(), _ => s.trim().to_string() } }

/// A reply message: Re: subject, threading headers, base64 UTF-8 body.
pub fn compose_reply(me: &str, original: &ReplyTo, body: &str, date_rfc2822: &str, unique: &str) -> Vec<u8> {
    let clean = |s: &str| s.chars().map(|c| if c.is_control() { ' ' } else { c }).collect::<String>();
    let subject = clean(original.subject);
    let subject = if subject.to_lowercase().starts_with("re:") { subject } else { format!("Re: {subject}") };
    let message_id = clean(original.message_id.trim_matches(|c| c == '<' || c == '>'));
    let mut refs: Vec<String> = original.references.iter().map(|r| clean(r)).collect(); if !message_id.is_empty() { refs.push(format!("<{message_id}>")); }
    let mut out = format!("From: {}\r\nTo: {} <{}>\r\nSubject: {subject}\r\nDate: {}\r\nMessage-ID: <{}@everyday.local>\r\nMIME-Version: 1.0\r\n", clean(me), clean(original.from_name), clean(original.from_address), clean(date_rfc2822), clean(unique));
    if !message_id.is_empty() { out.push_str(&format!("In-Reply-To: <{message_id}>\r\n")); }
    if !refs.is_empty() { out.push_str(&format!("References: {}\r\n", refs.join(" "))); }
    out.push_str("Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n");
    for chunk in B64.encode(body.as_bytes()).as_bytes().chunks(76) { out.push_str(std::str::from_utf8(chunk).unwrap()); out.push_str("\r\n"); }
    out.into_bytes()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};
    fn fake(auth: bool, good_pw: &'static str) -> (u16, Arc<Mutex<Vec<String>>>) {
        let log = Arc::new(Mutex::new(vec![])); let l2 = log.clone();
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap(); let port = l.local_addr().unwrap().port();
        std::thread::spawn(move || { for c in l.incoming().take(1) { let c = c.unwrap(); let mut w = c.try_clone().unwrap(); let mut r = BufReader::new(c); w.write_all(b"220 fake\r\n").unwrap(); let mut in_data = false;
            loop { let mut line = String::new(); if r.read_line(&mut line).unwrap_or(0) == 0 { return; } let line = line.trim_end().to_string(); l2.lock().unwrap().push(line.clone());
                if in_data { if line == "." { in_data = false; w.write_all(b"250 queued\r\n").unwrap(); } continue; }
                let up = line.to_uppercase();
                if up.starts_with("EHLO") { w.write_all(if auth { b"250-fake\r\n250 AUTH PLAIN\r\n" as &[u8] } else { b"250 fake\r\n" }).unwrap(); }
                else if up.starts_with("AUTH PLAIN") { let tok = line.split_whitespace().nth(2).unwrap_or(""); let dec = String::from_utf8(B64.decode(tok).unwrap_or_default()).unwrap_or_default(); w.write_all(if dec.ends_with(good_pw) { b"235 ok\r\n" as &[u8] } else { b"535 bad credentials\r\n" }).unwrap(); }
                else if up == "DATA" { in_data = true; w.write_all(b"354 go\r\n").unwrap(); } else if up == "QUIT" { w.write_all(b"221 bye\r\n").unwrap(); return; } else { w.write_all(b"250 ok\r\n").unwrap(); } } } });
        (port, log)
    }
    fn msg() -> Vec<u8> { compose_reply("me@example.com", &ReplyTo { from_name: "Oscar", from_address: "oscar@acme.com", subject: "Roadmap", message_id: "<a@x>", references: &[] }, "Yes, 3pm works. I will present.", "Thu, 05 Nov 2026 09:00:00 +1000", "u1") }
    #[test] fn sends_a_reply_with_auth_envelope_and_threading() {
        let (port, log) = fake(true, "apppassword");
        send(std::net::TcpStream::connect(("127.0.0.1", port)).unwrap(), "me@example.com", "apppassword", "me@example.com", &["oscar@acme.com".into()], &msg()).unwrap();
        let l = log.lock().unwrap().join("\n");
        assert!(l.contains("MAIL FROM:<me@example.com>") && l.contains("RCPT TO:<oscar@acme.com>") && l.contains("Subject: Re: Roadmap") && l.contains("In-Reply-To: <a@x>"));
        assert!(!l.contains("apppassword"));   // AUTH PLAIN is base64, the password never appears in clear
        assert!(l.contains(&B64.encode("Yes, 3pm works. I will present.")[..20]));
    }
    #[test] fn a_refused_password_is_an_auth_error() {
        let (port, _) = fake(true, "right");
        let e = send(std::net::TcpStream::connect(("127.0.0.1", port)).unwrap(), "me@example.com", "wrong", "me@example.com", &["d@x.y".into()], &msg()).unwrap_err();
        assert!(matches!(e, SmtpError::Auth(_)));
    }
    #[test] fn dot_lines_are_stuffed_and_no_recipient_is_refused() {
        let (port, log) = fake(false, "");
        send(std::net::TcpStream::connect(("127.0.0.1", port)).unwrap(), "u", "", "me@example.com", &["d@x.y".into()], b"Subject: s\r\n\r\n.hidden dot\r\n").unwrap();
        assert!(log.lock().unwrap().contains(&"..hidden dot".to_string()));
        assert!(send(std::io::Cursor::new(vec![]), "u", "", "a@b.c", &[], b"x").is_err());
    }
    #[test] fn bare_addresses() { assert_eq!(bare_address("Oscar F <oscar@acme.com>"), "oscar@acme.com"); assert_eq!(bare_address(" x@y.z "), "x@y.z"); }
    #[test] fn malformed_unicode_responses_return_an_error_without_panicking() {
        let mut stream = BufReader::new(std::io::Cursor::new("💥 broken response\r\n".as_bytes().to_vec()));
        assert!(matches!(reply(&mut stream), Err(SmtpError::Io(_))));
    }
    #[test] fn reply_headers_cannot_inject_new_headers() {
        let raw = compose_reply("me@example.com", &ReplyTo { from_name: "Oscar\r\nBcc: hidden@example.com", from_address: "oscar@acme.com", subject: "Roadmap\nX-Injected: yes", message_id: "a@x\r\nInjected: true", references: &["<root@x>\nOther: value".into()] }, "Reply body", "Thu, 05 Nov 2026 09:00:00 +1000", "id");
        let text = String::from_utf8(raw).unwrap();
        assert!(!text.contains("\r\nBcc:") && !text.contains("\nX-Injected:") && !text.contains("\r\nInjected:") && !text.contains("\nOther:"));
    }
    #[test] fn envelope_addresses_cannot_inject_smtp_commands() {
        let stream = std::io::Cursor::new(b"220 ready\r\n".to_vec());
        let result = send(stream, "u", "", "me@example.com", &["a@b.c>\r\nRCPT TO:<hidden@example.com".into()], b"body");
        assert!(matches!(result, Err(SmtpError::Rejected(_))));
    }
}
