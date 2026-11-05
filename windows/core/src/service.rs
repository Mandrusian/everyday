//! Mail sync: pulls new mail over IMAP into the local store, keeps flags in step and removes what left the inbox.
use crate::imap::{Imap, ImapError};
use crate::mailrules::Email;
use crate::mime;
use crate::store::Store;
use serde::{Deserialize, Serialize};
use std::io::{Read, Write};

/// Stored form of a message. New fields are optional or defaulted so mail saved by older versions still loads.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
pub struct StoredEmail {
    pub id: String, #[serde(rename = "threadId")] pub thread_id: String, pub from_name: String, pub from_address: String,
    pub subject: String, pub snippet: String, pub body: String, pub date: i64, pub unread: bool,
    #[serde(default)] pub attachment_names: Vec<String>, #[serde(default)] pub list_unsubscribe: Option<String>,
}
impl StoredEmail { pub fn to_email(&self) -> Email { Email { id: self.id.clone(), thread_id: self.thread_id.clone(), from_name: self.from_name.clone(), from_address: self.from_address.clone(), subject: self.subject.clone(), date: self.date } } }

pub fn make_id(validity: u32, uid: u32) -> String { format!("imap:{validity}:{uid}") }
pub fn parse_id(id: &str) -> Option<(u32, u32)> { let p: Vec<&str> = id.split(':').collect(); if p.len() == 3 && p[0] == "imap" { Some((p[1].parse().ok()?, p[2].parse().ok()?)) } else { None } }

fn fnv_short(s: &str) -> String { let mut h: u64 = 0xcbf29ce484222325; for b in s.bytes() { h ^= b as u64; h = h.wrapping_mul(0x100000001b3); } format!("{:08x}", (h >> 16) as u32) }

#[derive(Debug, Default, PartialEq)]
pub struct SyncReport { pub added: usize, pub removed: usize, pub flag_changes: usize }

/// One incremental sync of INBOX. `now` is only used when a message has no Date header.
pub fn sync<S: Read + Write>(c: &mut Imap<S>, store: &Store, now: i64) -> Result<SyncReport, ImapError> {
    let (validity, _) = c.select("INBOX")?;
    let mut known: Vec<StoredEmail> = store.all("email", 5000);
    if known.iter().any(|m| parse_id(&m.id).map_or(false, |(v, _)| v != validity)) {     // the mailbox was rebuilt on the server: start over
        for m in &known { let _ = store.delete("email", &m.id); } known.clear();
    }
    let last = known.iter().filter_map(|m| parse_id(&m.id).map(|(_, u)| u)).max().unwrap_or(0);
    let mut uids = c.uid_search(if last == 0 { "ALL" } else { "ALL" })?;
    uids.retain(|u| *u > last); uids.sort_unstable_by(|a, b| b.cmp(a)); uids.truncate(150);
    let mut report = SyncReport::default();
    for chunk in uids.chunks(8) {
        for f in c.uid_fetch(chunk, 400_000)? {
            let p = mime::parse(f.body.as_deref().unwrap_or(&[]));
            let body = p.body.trim().to_string();
            let snippet: String = body.replace('\n', " ").split_whitespace().collect::<Vec<_>>().join(" ").chars().take(160).collect();
            let thread = format!("t{}", fnv_short(&p.thread_key()));
            let m = StoredEmail { id: make_id(validity, f.uid), thread_id: thread, from_name: if p.from_name.is_empty() { p.from_address.clone() } else { p.from_name.clone() }, from_address: p.from_address.clone(),
                subject: if p.subject.is_empty() { "(no subject)".into() } else { p.subject.clone() }, snippet, body, date: now, unread: !f.flags.contains(&"\\seen".to_string()),
                attachment_names: p.attachment_names.clone(), list_unsubscribe: p.list_unsubscribe.clone() };
            store.put("email", &m.id, m.date as f64, &m).map_err(|e| ImapError::Io(e.to_string()))?; report.added += 1;
        }
    }
    // flag changes and removals for what we already hold
    if let Some(min) = known.iter().filter_map(|m| parse_id(&m.id).map(|(_, u)| u)).min() {
        let seen: std::collections::HashMap<u32, Vec<String>> = c.uid_flags(min)?.into_iter().map(|f| (f.uid, f.flags)).collect();
        for m in known {
            let Some((_, uid)) = parse_id(&m.id) else { continue };
            match seen.get(&uid) {
                None => { let _ = store.delete("email", &m.id); report.removed += 1; }
                Some(flags) => { let unread = !flags.contains(&"\\seen".to_string()); if unread != m.unread { let mut x = m.clone(); x.unread = unread; let _ = store.put("email", &x.id, x.date as f64, &x); report.flag_changes += 1; } }
            }
        }
    }
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::imap::fake::*;
    fn raw(subject: &str, refs: &str) -> String { format!("From: Dana <dana@acme.com>\r\nTo: me@example.com\r\nSubject: {subject}\r\nMessage-ID: <{subject}@x>\r\n{refs}\r\nBody of {subject}\r\n") }
    fn open(port: u16) -> Imap<std::net::TcpStream> { let mut c = Imap::new(std::net::TcpStream::connect(("127.0.0.1", port)).unwrap()); c.greeting().unwrap(); c.login("me@example.com", "apppassword").unwrap(); c }
    #[test] fn first_sync_then_incremental_then_flags_and_removals() {
        let (port, st) = serve(); let store = Store::open(None).unwrap();
        st.lock().unwrap().msgs.push(Msg { uid: 1, flags: vec![], raw: raw("Roadmap", "") });
        st.lock().unwrap().msgs.push(Msg { uid: 2, flags: vec!["\\Seen".into()], raw: raw("Re: Roadmap", "References: <Roadmap@x>\r\nIn-Reply-To: <Roadmap@x>\r\n") });
        st.lock().unwrap().msgs.push(Msg { uid: 3, flags: vec![], raw: raw("Invoice", "") });
        let mut c = open(port);
        assert_eq!(sync(&mut c, &store, 100).unwrap().added, 3);
        let all: Vec<StoredEmail> = store.all("email", 10);
        assert_eq!(all.len(), 3);
        let t = |s: &str| all.iter().find(|m| m.subject == s).unwrap().thread_id.clone();
        assert_eq!(t("Roadmap"), t("Re: Roadmap")); assert_ne!(t("Roadmap"), t("Invoice"));    // threads group by References
        assert!(all.iter().find(|m| m.subject == "Roadmap").unwrap().unread && !all.iter().find(|m| m.subject == "Re: Roadmap").unwrap().unread);
        assert_eq!(sync(&mut c, &store, 101).unwrap(), SyncReport::default());                  // nothing new
        st.lock().unwrap().msgs.push(Msg { uid: 4, flags: vec![], raw: raw("New one", "") });
        st.lock().unwrap().msgs[0].flags.push("\\Seen".into()); st.lock().unwrap().msgs.retain(|m| m.uid != 3);
        let r = sync(&mut c, &store, 102).unwrap();
        assert_eq!((r.added, r.removed, r.flag_changes), (1, 1, 1));
        assert_eq!(store.all::<StoredEmail>("email", 10).len(), 3);
    }
    #[test] fn ids_round_trip() { assert_eq!(parse_id(&make_id(7, 42)), Some((7, 42))); assert_eq!(parse_id("gmail:1"), None); }
    #[test] fn old_stored_mail_without_new_fields_still_loads() {
        let store = Store::open(None).unwrap();
        store.put("email", "old", 0.0, &serde_json::json!({"id":"old","threadId":"t","from_name":"A","from_address":"a@b.c","subject":"s","snippet":"","body":"","date":0,"unread":true})).unwrap();
        let m: StoredEmail = store.get("email", "old").unwrap(); assert!(m.attachment_names.is_empty() && m.list_unsubscribe.is_none());
    }
}
