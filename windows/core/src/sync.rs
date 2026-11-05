//! Wi-Fi sync between a person's own devices. No server: devices in the same sync group find each other
//! on the local network (`_everyday._tcp`), and each exchange is encrypted with the group key that was
//! shared once by QR code. The Mac app speaks the same format (Sources/EverydayCore/Sync).
//!
//! Wire: a frame is a 4-byte big-endian length, then a 12-byte nonce and ChaCha20-Poly1305 ciphertext.
//! The plaintext is a JSON `Hello`. The client sends its whole state; the server merges and replies with
//! the merged state; the client merges that. Data is small (tasks, topics, flags), so full state is fine.
//!
//! Records merge last-writer-wins on (time, device). Deletions are kept as `del: true` so they spread.

use base64::{engine::general_purpose::URL_SAFE_NO_PAD as B64, Engine};
use chacha20poly1305::{aead::Aead, ChaCha20Poly1305, KeyInit, Nonce};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::time::Duration;

pub const SERVICE: &str = "_everyday._tcp.local.";
const MAX_FRAME: usize = 16 * 1024 * 1024;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Record {
    /// The value; null when deleted.
    #[serde(default)]
    pub v: serde_json::Value,
    /// Changed at, in milliseconds since 1970.
    pub t: i64,
    /// Device that made the change; breaks ties.
    pub d: String,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub del: bool,
}

impl Record {
    fn newer_than(&self, other: &Record) -> bool { (self.t, &self.d) > (other.t, &other.d) }
}

/// Keys are "kind:id", such as "task:42", "topic:science", "handled:<thread>", "saved:<url>", "pref:briefing.hour".
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct State { pub records: BTreeMap<String, Record> }

impl State {
    pub fn set(&mut self, key: &str, v: serde_json::Value, now: i64, device: &str) {
        self.records.insert(key.into(), Record { v, t: now, d: device.into(), del: false });
    }
    pub fn delete(&mut self, key: &str, now: i64, device: &str) {
        self.records.insert(key.into(), Record { v: serde_json::Value::Null, t: now, d: device.into(), del: true });
    }
    /// Merges `other` in. Returns the keys whose value changed here, so the app can apply just those.
    pub fn merge(&mut self, other: &State) -> Vec<String> {
        let mut changed = vec![];
        for (k, r) in &other.records {
            match self.records.get(k) {
                Some(mine) if !r.newer_than(mine) => {}
                _ => { self.records.insert(k.clone(), r.clone()); changed.push(k.clone()); }
            }
        }
        changed
    }
    /// Live (not deleted) records of one kind, keyed by id.
    pub fn live(&self, kind: &str) -> Vec<(String, &serde_json::Value)> {
        let p = format!("{kind}:");
        self.records.iter().filter(|(k, r)| !r.del && k.starts_with(&p)).map(|(k, r)| (k[p.len()..].to_string(), &r.v)).collect()
    }
}

#[derive(Debug, Serialize, Deserialize)]
pub struct Hello {
    pub device: String, pub name: String, pub state: State,
    /// From a newly paired device: the one-time token in the pairing code, asking for the setup bundle.
    #[serde(default, rename = "setupToken", skip_serializing_if = "Option::is_none")] pub setup_token: Option<String>,
    /// The setup bundle (accounts, keys, settings), in reply to a valid token.
    #[serde(default, skip_serializing_if = "Option::is_none")] pub setup: Option<serde_json::Value>,
}

#[derive(Debug)]
pub enum SyncError { Io(String), Crypto, Format(String) }
impl std::fmt::Display for SyncError {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        match self {
            SyncError::Io(e) => write!(f, "Couldn't reach the other device: {e}"),
            SyncError::Crypto => write!(f, "The other device isn't paired with this one."),
            SyncError::Format(e) => write!(f, "The other device sent something unexpected: {e}"),
        }
    }
}
impl From<std::io::Error> for SyncError { fn from(e: std::io::Error) -> Self { SyncError::Io(e.to_string()) } }

/// A sync group: the 32-byte key every paired device holds.
#[derive(Clone)]
pub struct Group { key: [u8; 32] }

impl Group {
    pub fn new() -> Self { let mut key = [0u8; 32]; getrandom::getrandom(&mut key).expect("random"); Group { key } }
    pub fn from_key(b64: &str) -> Option<Self> { B64.decode(b64).ok()?.try_into().ok().map(|key| Group { key }) }
    pub fn key_b64(&self) -> String { B64.encode(self.key) }
    /// Public, short id advertised on the network so devices only talk to their own group. Reveals nothing about the key.
    pub fn id(&self) -> String { let h = Sha256::digest([b"everyday-sync-group".as_slice(), &self.key].concat()); hex(&h[..8]) }
    /// What the QR code holds.
    pub fn pairing_uri(&self) -> String { format!("everyday-sync:1:{}", self.key_b64()) }
    /// "everyday-sync:1:<key>" or "everyday-sync:1:<key>:<setup token>".
    pub fn from_pairing_uri(s: &str) -> Option<Self> { Self::from_key(s.trim().strip_prefix("everyday-sync:1:")?.split(':').next()?) }
    pub fn setup_token(s: &str) -> Option<String> { s.trim().split(':').nth(3).map(String::from) }

    pub fn seal(&self, plain: &[u8]) -> Vec<u8> {
        let mut n = [0u8; 12]; getrandom::getrandom(&mut n).expect("random");
        let ct = ChaCha20Poly1305::new((&self.key).into()).encrypt(Nonce::from_slice(&n), plain).expect("encrypt");
        [n.as_slice(), &ct].concat()
    }
    pub fn open(&self, sealed: &[u8]) -> Result<Vec<u8>, SyncError> {
        if sealed.len() < 28 { return Err(SyncError::Crypto); }
        ChaCha20Poly1305::new((&self.key).into()).decrypt(Nonce::from_slice(&sealed[..12]), &sealed[12..]).map_err(|_| SyncError::Crypto)
    }

    fn send(&self, s: &mut TcpStream, h: &Hello) -> Result<(), SyncError> {
        let body = self.seal(&serde_json::to_vec(h).map_err(|e| SyncError::Format(e.to_string()))?);
        s.write_all(&(body.len() as u32).to_be_bytes())?; s.write_all(&body)?; s.flush()?; Ok(())
    }
    fn recv(&self, s: &mut TcpStream) -> Result<Hello, SyncError> {
        let mut len = [0u8; 4]; s.read_exact(&mut len)?;
        let n = u32::from_be_bytes(len) as usize;
        if n > MAX_FRAME { return Err(SyncError::Format("frame too large".into())); }
        let mut buf = vec![0u8; n]; s.read_exact(&mut buf)?;
        serde_json::from_slice(&self.open(&buf)?).map_err(|e| SyncError::Format(e.to_string()))
    }

    /// Client side: send our state, take theirs. Returns the peer's name and the keys that changed locally.
    pub fn exchange(&self, addr: &str, me: &Hello, state: &mut State) -> Result<(String, Vec<String>), SyncError> {
        self.exchange_full(addr, me, state).map(|(n, c, _)| (n, c))
    }
    /// Like `exchange`, also returning a setup bundle if the peer sent one.
    pub fn exchange_full(&self, addr: &str, me: &Hello, state: &mut State) -> Result<(String, Vec<String>, Option<serde_json::Value>), SyncError> {
        let sa = addr.parse().map_err(|_| SyncError::Io(format!("bad address {addr}")))?;
        let mut s = TcpStream::connect_timeout(&sa, Duration::from_secs(4))?;
        s.set_read_timeout(Some(Duration::from_secs(15)))?;
        self.send(&mut s, me)?;
        let theirs = self.recv(&mut s)?;
        Ok((theirs.name, state.merge(&theirs.state), theirs.setup))
    }

    /// Server side, for one accepted connection: merge theirs, reply with the merged state.
    /// `setup` decides, from the peer's token, whether to hand over the setup bundle.
    pub fn serve(&self, mut s: TcpStream, device: &str, name: &str, state: &mut State, setup: &dyn Fn(Option<&str>) -> Option<serde_json::Value>) -> Result<(String, Vec<String>), SyncError> {
        s.set_read_timeout(Some(Duration::from_secs(15)))?;
        let theirs = self.recv(&mut s)?;
        let changed = state.merge(&theirs.state);
        self.send(&mut s, &Hello { device: device.into(), name: name.into(), state: state.clone(), setup_token: None, setup: setup(theirs.setup_token.as_deref()) })?;
        Ok((theirs.name, changed))
    }
}

impl Default for Group { fn default() -> Self { Self::new() } }

/// Matches the same conversation across devices whose mail ids differ (Gmail API on the Mac, IMAP elsewhere):
/// sender address plus subject without reply prefixes. Used for "handled" flags.
pub fn mail_key(from_address: &str, subject: &str) -> String {
    let mut s = subject.trim().to_lowercase();
    loop {
        let t = ["re:", "fwd:", "fw:"].iter().find_map(|p| s.strip_prefix(p).map(|r| r.trim_start().to_string()));
        match t { Some(t) => s = t, None => break }
    }
    let s = s.split_whitespace().collect::<Vec<_>>().join(" ");
    hex(&Sha256::digest(format!("{}|{}", from_address.trim().to_lowercase(), s).as_bytes())[..8])
}

/// A random id for this device, made once.
pub fn new_device_id() -> String { let mut b = [0u8; 8]; getrandom::getrandom(&mut b).expect("random"); hex(&b) }

fn hex(b: &[u8]) -> String { b.iter().map(|x| format!("{x:02x}")).collect() }

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn newest_wins_and_deletes_spread() {
        let mut a = State::default(); let mut b = State::default();
        a.set("task:1", json!({"title": "Pay rent"}), 100, "mac");
        b.set("task:1", json!({"title": "Pay rent today"}), 200, "phone");
        b.delete("task:2", 50, "phone");
        let changed = a.merge(&b);
        assert_eq!(a.records["task:1"].v["title"], "Pay rent today");
        assert!(a.records["task:2"].del);
        assert_eq!(changed.len(), 2);
        assert!(b.merge(&a).is_empty(), "merging back changes nothing");
        // Ties break on device id, the same on both sides.
        let mut x = State::default(); let mut y = State::default();
        x.set("k:1", json!(1), 5, "a"); y.set("k:1", json!(2), 5, "b");
        x.merge(&y); y.merge(&x); assert_eq!(x, y);
        assert_eq!(a.live("task").len(), 1);
    }

    #[test]
    fn sealed_round_trip_and_wrong_group() {
        let g = Group::new();
        assert_eq!(g.open(&g.seal(b"hi")).unwrap(), b"hi");
        assert!(Group::new().open(&g.seal(b"hi")).is_err());
        let back = Group::from_pairing_uri(&g.pairing_uri()).unwrap();
        assert_eq!(back.id(), g.id());
    }

    /// Fixed vectors shared with the Swift checks (EverydayChecks "sync: interop").
    #[test]
    fn interop_vector() {
        let g = Group::from_key("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8").unwrap();
        assert_eq!(g.id(), INTEROP_GROUP_ID);
        let sealed = B64.decode(INTEROP_SEALED).unwrap();
        assert_eq!(g.open(&sealed).unwrap(), b"everyday.");
    }
    #[test]
    fn mail_key_ignores_reply_prefixes() {
        assert_eq!(mail_key("A@x.com", "Re: FWD:  Lease   renewal"), mail_key("a@x.com", "lease renewal"));
        assert_eq!(mail_key("a@x.com", "lease renewal"), INTEROP_MAIL_KEY);
    }
    pub const INTEROP_MAIL_KEY: &str = "d36a0a59c18320fc";
    pub const INTEROP_GROUP_ID: &str = "4419e5b0d61c293a";
    pub const INTEROP_SEALED: &str = "ZGVmZ2hpamtsbW5vUWfeuOHBFyvV-BLfLwERKFJTnBHQI1vuOw";

    #[test]
    fn tcp_exchange() {
        let g = Group::new();
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = l.local_addr().unwrap().to_string();
        let g2 = g.clone();
        let t = std::thread::spawn(move || {
            let mut srv = State::default(); srv.set("topic:science", json!(true), 10, "mac");
            let (peer, _) = g2.serve(l.accept().unwrap().0, "mac", "Mac", &mut srv, &|_| None).unwrap();
            (peer, srv)
        });
        let mut cli = State::default(); cli.set("task:9", json!({"title": "Call Oscar"}), 20, "phone");
        let me = Hello { device: "phone".into(), name: "Phone".into(), state: cli.clone(), setup_token: None, setup: None };
        let (peer, changed) = g.exchange(&addr, &me, &mut cli).unwrap();
        let (cpeer, srv) = t.join().unwrap();
        assert_eq!((peer.as_str(), cpeer.as_str()), ("Mac", "Phone"));
        assert_eq!(changed, vec!["topic:science".to_string()]);
        assert_eq!(cli, srv);
    }
}
