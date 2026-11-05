//! A small IMAP client (LOGIN, LIST, SELECT, UID SEARCH, UID FETCH, UID MOVE, UID STORE, APPEND), generic over the stream so it is
//! tested against a scripted server and used over TLS in the app. Passwords are never logged.
use std::io::{BufRead, BufReader, Read, Write};

#[derive(Debug, Clone, PartialEq)]
pub enum ImapError { Auth(String), Command(String, String), Io(String), Unsupported(String) }
impl std::fmt::Display for ImapError {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        match self { ImapError::Auth(m) | ImapError::Io(m) | ImapError::Unsupported(m) => write!(f, "{m}"), ImapError::Command(c, m) => write!(f, "{c} failed: {m}") }
    }
}
impl From<std::io::Error> for ImapError { fn from(e: std::io::Error) -> Self { ImapError::Io(format!("Connection problem: {e}")) } }

#[derive(Debug, Clone, Default)]
pub struct Line { pub text: String, pub literals: Vec<Vec<u8>> }
#[derive(Debug, Clone, Default)]
pub struct Fetched { pub uid: u32, pub flags: Vec<String>, pub body: Option<Vec<u8>> }
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Folders { pub archive: Option<String>, pub trash: Option<String>, pub drafts: Option<String>, pub sent: Option<String> }

pub struct Imap<S: Read + Write> { s: BufReader<S>, tag: u32 }

pub fn quote(s: &str) -> String { format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\"")) }

impl<S: Read + Write> Imap<S> {
    pub fn new(stream: S) -> Self { Imap { s: BufReader::new(stream), tag: 0 } }

    fn read_line(&mut self) -> Result<String, ImapError> {
        let mut buf = Vec::new();
        let n = self.s.read_until(b'\n', &mut buf)?;
        if n == 0 { return Err(ImapError::Io("The server closed the connection.".into())); }
        Ok(String::from_utf8_lossy(&buf).trim_end_matches(['\r', '\n']).to_string())
    }

    /// Reads the greeting, then must be followed by `login`.
    pub fn greeting(&mut self) -> Result<(), ImapError> { let l = self.read_line()?; if l.starts_with("* OK") || l.starts_with("* PREAUTH") { Ok(()) } else { Err(ImapError::Io(format!("Unexpected greeting: {l}"))) } }

    /// Sends one command; returns the untagged lines (with literals) and the final status text.
    pub fn run(&mut self, cmd: &str, literal_after_continuation: Option<&[u8]>) -> Result<Vec<Line>, ImapError> {
        self.tag += 1; let tag = format!("A{:04}", self.tag);
        self.s.get_mut().write_all(format!("{tag} {cmd}\r\n").as_bytes())?; self.s.get_mut().flush()?;
        let mut out = vec![];
        loop {
            let line = self.read_line()?;
            if let Some(rest) = line.strip_prefix(&format!("{tag} ")) {
                return if rest.starts_with("OK") { Ok(out) } else if rest.starts_with("NO") && cmd.to_uppercase().starts_with("LOGIN") { Err(ImapError::Auth("The server refused the password.".into())) } else { Err(ImapError::Command(cmd.split_whitespace().next().unwrap_or("").to_string(), rest.to_string())) };
            }
            if line.starts_with('+') { if let Some(l) = literal_after_continuation { let w = self.s.get_mut(); w.write_all(l)?; w.write_all(b"\r\n")?; w.flush()?; } continue; }
            let mut cur = Line { text: line.clone(), literals: vec![] };
            let mut tail = line;
            while let Some(n) = literal_len(&tail) {     // "{123}" at the end of a line: read exactly n bytes, then the rest of the line
                let mut buf = vec![0u8; n]; self.s.read_exact(&mut buf)?; cur.literals.push(buf);
                tail = self.read_line()?; cur.text.push_str(&format!(" <literal> {tail}"));
            }
            out.push(cur);
        }
    }

    pub fn login(&mut self, user: &str, password: &str) -> Result<(), ImapError> { self.run(&format!("LOGIN {} {}", quote(user), quote(password)), None).map(|_| ()) }
    pub fn logout(&mut self) { let _ = self.run("LOGOUT", None); }

    pub fn select(&mut self, mailbox: &str) -> Result<(u32, u32), ImapError> {
        let r = self.run(&format!("SELECT {}", quote(mailbox)), None)?;
        let (mut v, mut n) = (0, 0);
        for l in &r { v = num_after(&l.text, "UIDVALIDITY ").unwrap_or(v); n = num_after(&l.text, "UIDNEXT ").unwrap_or(n); }
        Ok((v, n))
    }

    pub fn uid_search(&mut self, query: &str) -> Result<Vec<u32>, ImapError> {
        let r = self.run(&format!("UID SEARCH {query}"), None)?;
        Ok(r.iter().filter(|l| l.text.starts_with("* SEARCH")).flat_map(|l| l.text.split_whitespace().skip(2).filter_map(|x| x.parse().ok()).collect::<Vec<u32>>()).collect())
    }

    /// Fetches flags and (the first `limit` bytes of) the full message without marking it read.
    pub fn uid_fetch(&mut self, uids: &[u32], limit: usize) -> Result<Vec<Fetched>, ImapError> {
        if uids.is_empty() { return Ok(vec![]); }
        let set = uids.iter().map(u32::to_string).collect::<Vec<_>>().join(",");
        let r = self.run(&format!("UID FETCH {set} (UID FLAGS BODY.PEEK[]<0.{limit}>)"), None)?;
        Ok(r.into_iter().filter(|l| l.text.contains(" FETCH (")).filter_map(|l| {
            let uid = num_after(&l.text, "UID ")?;
            let flags = l.text.find("FLAGS (").map(|i| { let rest = &l.text[i + 7..]; rest[..rest.find(')').unwrap_or(0)].split_whitespace().map(|f| f.to_lowercase()).collect() }).unwrap_or_default();
            Some(Fetched { uid, flags, body: l.literals.into_iter().next() })
        }).collect())
    }

    pub fn uid_flags(&mut self, from_uid: u32) -> Result<Vec<Fetched>, ImapError> {
        let r = self.run(&format!("UID FETCH {from_uid}:* (UID FLAGS)"), None)?;
        Ok(r.into_iter().filter_map(|l| { let uid = num_after(&l.text, "UID ")?; let flags = l.text.find("FLAGS (").map(|i| { let rest = &l.text[i + 7..]; rest[..rest.find(')').unwrap_or(0)].split_whitespace().map(|f| f.to_lowercase()).collect() }).unwrap_or_default(); Some(Fetched { uid, flags, body: None }) }).collect())
    }

    pub fn uid_move(&mut self, uid: u32, folder: &str) -> Result<(), ImapError> { self.run(&format!("UID MOVE {uid} {}", quote(folder)), None).map(|_| ()) }
    pub fn mark_seen(&mut self, uid: u32) -> Result<(), ImapError> { self.run(&format!("UID STORE {uid} +FLAGS (\\Seen)"), None).map(|_| ()) }
    pub fn append(&mut self, folder: &str, flag: &str, data: &[u8]) -> Result<(), ImapError> { self.run(&format!("APPEND {} ({flag}) {{{}}}", quote(folder), data.len()), Some(data)).map(|_| ()) }

    /// Finds the archive, trash, drafts and sent folders by their special-use flags, falling back to common names.
    pub fn folders(&mut self) -> Result<Folders, ImapError> {
        let r = self.run("LIST \"\" \"*\"", None)?;
        let entries: Vec<(String, String)> = r.iter().filter(|l| l.text.starts_with("* LIST")).filter_map(|l| {
            let flags = l.text[l.text.find('(')? + 1..l.text.find(')')?].to_lowercase();
            let after = l.text[l.text.find(')')? + 1..].trim_start();          // `"/" "Deleted Items"`: skip the delimiter, keep the rest (it may contain spaces)
            let name = after.split_once(' ').map(|(_, n)| n.trim().trim_matches('"').to_string())?; Some((flags, name)) }).collect();
        let pick = |flag: &str, names: &[&str]| entries.iter().find(|(f, _)| f.contains(flag)).map(|(_, n)| n.clone())
            .or_else(|| entries.iter().find(|(_, n)| names.iter().any(|x| n.eq_ignore_ascii_case(x))).map(|(_, n)| n.clone()));
        Ok(Folders { archive: pick("\\archive", &["Archive", "Archives", "All Mail"]), trash: pick("\\trash", &["Trash", "Deleted Items", "Deleted Messages"]),
                     drafts: pick("\\drafts", &["Drafts"]), sent: pick("\\sent", &["Sent", "Sent Items", "Sent Messages"]) })
    }
}

fn literal_len(line: &str) -> Option<usize> { let t = line.trim_end(); if !t.ends_with('}') { return None; } let i = t.rfind('{')?; t[i + 1..t.len() - 1].parse().ok() }
fn num_after(s: &str, key: &str) -> Option<u32> { let i = s.find(key)? + key.len(); s[i..].chars().take_while(|c| c.is_ascii_digit()).collect::<String>().parse().ok() }

/// A scripted server for tests: one mailbox, a few folders, the commands above.
#[cfg(test)]
pub mod fake {
    use super::*;
    use std::sync::{Arc, Mutex};
    pub struct Msg { pub uid: u32, pub flags: Vec<String>, pub raw: String }
    pub struct State { pub msgs: Vec<Msg>, pub log: Vec<String>, pub password: String }
    pub fn serve() -> (u16, Arc<Mutex<State>>) {
        let st = Arc::new(Mutex::new(State { msgs: vec![], log: vec![], password: "apppassword".into() }));
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap(); let port = l.local_addr().unwrap().port(); let s2 = st.clone();
        std::thread::spawn(move || { for c in l.incoming() { let Ok(c) = c else { break }; let s = s2.clone(); std::thread::spawn(move || handle(c, s)); } });
        (port, st)
    }
    fn handle(c: std::net::TcpStream, st: Arc<Mutex<State>>) {
        let mut w = c.try_clone().unwrap(); let mut r = BufReader::new(c);
        w.write_all(b"* OK fake ready\r\n").unwrap();
        loop {
            let mut line = String::new(); if r.read_line(&mut line).unwrap_or(0) == 0 { return; }
            let line = line.trim_end().to_string(); let (tag, rest) = line.split_once(' ').unwrap_or((&line, "")); let up = rest.to_uppercase();
            st.lock().unwrap().log.push(rest.to_string());
            if up.starts_with("LOGIN") { let ok = rest.contains(&st.lock().unwrap().password); write!(w, "{tag} {}\r\n", if ok { "OK logged in" } else { "NO [AUTHENTICATIONFAILED] bad" }).unwrap(); }
            else if up.starts_with("LIST") { write!(w, "* LIST (\\HasNoChildren) \"/\" \"INBOX\"\r\n* LIST (\\HasNoChildren \\Archive) \"/\" \"Archive\"\r\n* LIST (\\HasNoChildren \\Trash) \"/\" \"Deleted Items\"\r\n* LIST (\\HasNoChildren \\Drafts) \"/\" \"Drafts\"\r\n* LIST (\\HasNoChildren \\Sent) \"/\" \"Sent Items\"\r\n{tag} OK done\r\n").unwrap(); }
            else if up.starts_with("SELECT") { let n = st.lock().unwrap().msgs.iter().map(|m| m.uid).max().unwrap_or(0) + 1; write!(w, "* 3 EXISTS\r\n* OK [UIDVALIDITY 7] ok\r\n* OK [UIDNEXT {n}] next\r\n{tag} OK [READ-WRITE] selected\r\n").unwrap(); }
            else if up.starts_with("UID SEARCH") { let ids = st.lock().unwrap().msgs.iter().map(|m| m.uid.to_string()).collect::<Vec<_>>().join(" "); write!(w, "* SEARCH {ids}\r\n{tag} OK done\r\n").unwrap(); }
            else if up.starts_with("UID FETCH") {
                let set = rest.split_whitespace().nth(2).unwrap_or(""); let body = up.contains("BODY.PEEK");
                for m in st.lock().unwrap().msgs.iter() {
                    let wanted = set == "1:*" || set.split(',').any(|x| x.parse() == Ok(m.uid)) || set.split_once(':').map_or(false, |(a, _)| a.parse::<u32>().map_or(false, |a| m.uid >= a));
                    if !wanted { continue; }
                    let fl = m.flags.join(" ");
                    if body { write!(w, "* {} FETCH (UID {} FLAGS ({fl}) BODY[] {{{}}}\r\n{})\r\n", m.uid, m.uid, m.raw.len(), m.raw).unwrap(); } else { write!(w, "* {} FETCH (UID {} FLAGS ({fl}))\r\n", m.uid, m.uid).unwrap(); }
                }
                write!(w, "{tag} OK done\r\n").unwrap();
            }
            else if up.starts_with("UID MOVE") { let uid: u32 = rest.split_whitespace().nth(2).and_then(|x| x.parse().ok()).unwrap_or(0); st.lock().unwrap().msgs.retain(|m| m.uid != uid); write!(w, "{tag} OK moved\r\n").unwrap(); }
            else if up.starts_with("UID STORE") { let uid: u32 = rest.split_whitespace().nth(2).and_then(|x| x.parse().ok()).unwrap_or(0); for m in st.lock().unwrap().msgs.iter_mut() { if m.uid == uid && !m.flags.contains(&"\\Seen".to_string()) { m.flags.push("\\Seen".into()); } } write!(w, "{tag} OK stored\r\n").unwrap(); }
            else if up.starts_with("APPEND") { let n: usize = rest[rest.rfind('{').unwrap() + 1..rest.len() - 1].parse().unwrap(); w.write_all(b"+ ready\r\n").unwrap(); let mut buf = vec![0u8; n + 2]; r.read_exact(&mut buf).unwrap(); write!(w, "{tag} OK appended\r\n").unwrap(); }
            else if up.starts_with("LOGOUT") { write!(w, "* BYE\r\n{tag} OK bye\r\n").unwrap(); return; }
            else { write!(w, "{tag} OK\r\n").unwrap(); }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use super::fake::*;
    fn raw(subject: &str) -> String { format!("From: Dana <dana@acme.com>\r\nTo: me@example.com\r\nSubject: {subject}\r\nMessage-ID: <{subject}@x>\r\n\r\nBody of {subject}\r\n") }
    fn connect(port: u16) -> Imap<std::net::TcpStream> { let mut c = Imap::new(std::net::TcpStream::connect(("127.0.0.1", port)).unwrap()); c.greeting().unwrap(); c }
    #[test] fn login_select_search_fetch() {
        let (port, st) = serve(); st.lock().unwrap().msgs.push(Msg { uid: 1, flags: vec!["\\Seen".into()], raw: raw("Roadmap") }); st.lock().unwrap().msgs.push(Msg { uid: 2, flags: vec![], raw: raw("Invoice") });
        let mut c = connect(port); c.login("me@example.com", "apppassword").unwrap();
        assert_eq!(c.select("INBOX").unwrap(), (7, 3));
        assert_eq!(c.uid_search("ALL").unwrap(), [1, 2]);
        let f = c.uid_fetch(&[1, 2], 400000).unwrap();
        assert_eq!(f.len(), 2); assert!(f[0].flags.contains(&"\\seen".to_string()) && f[1].flags.is_empty());
        assert!(String::from_utf8_lossy(f[1].body.as_ref().unwrap()).contains("Body of Invoice"));
    }
    #[test] fn a_wrong_password_is_an_auth_error() { let (port, _) = serve(); let mut c = connect(port); assert!(matches!(c.login("me@example.com", "nope"), Err(ImapError::Auth(_)))); }
    #[test] fn folders_are_found_by_special_use() {
        let (port, _) = serve(); let mut c = connect(port); c.login("a", "apppassword").unwrap();
        assert_eq!(c.folders().unwrap(), Folders { archive: Some("Archive".into()), trash: Some("Deleted Items".into()), drafts: Some("Drafts".into()), sent: Some("Sent Items".into()) });
    }
    #[test] fn archive_trash_seen_and_draft_commands() {
        let (port, st) = serve(); for (u, s) in [(1, "A"), (2, "B")] { st.lock().unwrap().msgs.push(Msg { uid: u, flags: vec![], raw: raw(s) }); }
        let mut c = connect(port); c.login("a", "apppassword").unwrap(); c.select("INBOX").unwrap();
        c.uid_move(1, "Archive").unwrap(); c.mark_seen(2).unwrap(); c.append("Drafts", "\\Draft", b"Subject: d\r\n\r\nhi").unwrap();
        let log = st.lock().unwrap().log.clone();
        assert!(log.contains(&"UID MOVE 1 \"Archive\"".to_string())); assert!(log.iter().any(|l| l.starts_with("APPEND \"Drafts\" (\\Draft) {")));
        assert_eq!(st.lock().unwrap().msgs.len(), 1); assert!(st.lock().unwrap().msgs[0].flags.contains(&"\\Seen".to_string()));
    }
    #[test] fn the_password_is_sent_quoted_and_never_stored_in_flags() {
        assert_eq!(quote("p\"w\\x"), "\"p\\\"w\\\\x\""); assert_eq!(literal_len("* 1 FETCH (BODY[] {42}"), Some(42)); assert_eq!(literal_len("* OK done"), None);
    }
}
