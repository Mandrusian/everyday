//! Wi-Fi sync for Android and Windows: turns local data into sync records, runs the listener and mDNS,
//! and applies what other devices send. The protocol and merge live in `everyday_core::sync`.
//!
//! Change detection needs no hooks in every command: before each exchange, `prepare` compares the data as it
//! is now with the last synced state and stamps whatever differs. Synced kinds: tasks, news topics, handled mail.
//! Records of kinds this device doesn't use (the Mac's saved stories) are kept and passed on unchanged.

use super::*;
use everyday_core::sync::{self, Group, Hello, State};
use mdns_sd::{ServiceDaemon, ServiceEvent, ServiceInfo};
use std::net::TcpListener;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

pub const KEY_SECRET: &str = "sync.key";

#[derive(Default)]
struct Host {
    group: Option<Group>,
    port: u16,
    daemon: Option<ServiceDaemon>,
    /// device id -> (name, "ip:port")
    peers: HashMap<String, (String, String)>,
    /// device id -> (name, unix seconds)
    last: HashMap<String, (String, i64)>,
    stop: Option<Arc<AtomicBool>>,
    error: Option<String>,
    /// Bumped whenever another device changed data here, so the UI knows to reload.
    changes: u64,
    /// Offered with the pairing code: (token, valid until). One use.
    offer: Option<(String, i64)>,
    /// The secrets to hand over with the offer, captured when the code was shown (the listener has no Keystore access).
    offer_secrets: HashMap<String, String>,
    /// From a scanned code: sent with the next exchange to ask for setup.
    want: Option<String>,
    /// A setup bundle that arrived, waiting for the UI to apply its secrets.
    received: Option<Value>,
}

static HOST: OnceCell<Mutex<Host>> = OnceCell::new();
fn host() -> std::sync::MutexGuard<'static, Host> { HOST.get_or_init(Default::default).lock().unwrap_or_else(|e| e.into_inner()) }

fn now_ms() -> i64 { chrono::Utc::now().timestamp_millis() }

pub fn device_id(st: &Store) -> String {
    let id = pref(st, "sync.device");
    if !id.is_empty() { return id; }
    let id = sync::new_device_id(); let _ = st.put("pref", "sync.device", 0.0, &id); id
}
pub fn device_name(st: &Store) -> String { let n = pref(st, "sync.name"); if n.is_empty() { default_name().into() } else { n } }
fn default_name() -> &'static str { if cfg!(target_os = "android") { "Android phone" } else if cfg!(windows) { "Windows PC" } else { "This computer" } }

fn load_state(st: &Store) -> State { st.get("sync", "state").unwrap_or_default() }
fn save_state(st: &Store, s: &State) { let _ = st.put("sync", "state", 0.0, s); }

fn task_value(t: &tasks::Task) -> Value {
    json!({ "title": t.title, "notes": t.notes, "due": t.due, "done": t.completed_at, "priority": t.priority, "created": t.created_at, "repeats": t.repeats })
}

/// The synced view of local data, as it is right now.
fn export(st: &Store) -> HashMap<String, Value> {
    let mut m = HashMap::new();
    for t in st.all::<tasks::Task>("task", 100000) { m.insert(format!("task:{}", t.id), task_value(&t)); }
    for c in pref(st, "categories").split(',').filter(|c| !c.is_empty()) { m.insert(format!("topic:{c}"), json!(true)); }
    let handled: std::collections::HashSet<String> = st.all::<String>("handledThread", 5000).into_iter().collect();
    for e in st.all::<service::StoredEmail>("email", 5000) {
        if handled.contains(&e.thread_id) { m.insert(format!("handled:{}", sync::mail_key(&e.from_address, &e.subject)), json!(true)); }
    }
    m
}

/// Stamps local changes since the last sync into the state. Handled flags are never removed this way,
/// because a flag for mail this device hasn't downloaded yet would look like a removal.
fn prepare(st: &Store, me: &str) -> State {
    let mut state = load_state(st);
    let now = now_ms();
    let local = export(st);
    for (k, v) in &local {
        match state.records.get(k) { Some(r) if !r.del && &r.v == v => {} _ => state.set(k, v.clone(), now, me) }
    }
    let gone: Vec<String> = state.records.iter().filter(|(k, r)| !r.del && (k.starts_with("task:") || k.starts_with("topic:")) && !local.contains_key(*k)).map(|(k, _)| k.clone()).collect();
    for k in gone { state.delete(&k, now, me); }
    // Handled flags that arrived before their mail did.
    apply(st, &state, &state.records.keys().filter(|k| k.starts_with("handled:")).cloned().collect::<Vec<_>>());
    save_state(st, &state);
    state
}

/// Writes changed records into local data.
fn apply(st: &Store, state: &State, keys: &[String]) {
    let mut topics_changed = false;
    let mut handled: Vec<(&str, bool)> = vec![];
    for k in keys {
        let Some(r) = state.records.get(k) else { continue };
        let Some((kind, id)) = k.split_once(':') else { continue };
        match kind {
            "task" if r.del => { let _ = st.delete("task", id); }
            "task" => {
                let v = &r.v;
                let t = tasks::Task { id: id.into(), title: v["title"].as_str().unwrap_or("").into(), notes: v["notes"].as_str().unwrap_or("").into(), due: v["due"].as_i64(),
                    priority: v["priority"].as_str().unwrap_or("medium").into(), thread_id: None, completed_at: v["done"].as_i64(), created_at: v["created"].as_i64().unwrap_or(0),
                    repeats: v["repeats"].as_str().map(String::from) };
                let _ = st.put("task", id, t.due.unwrap_or(t.created_at) as f64, &t);
            }
            "topic" => topics_changed = true,
            "handled" => handled.push((id, !r.del)),
            _ => {}
        }
    }
    if topics_changed {
        let mut c: Vec<String> = state.live("topic").into_iter().map(|(id, _)| id).collect(); c.sort();
        let _ = st.put("pref", "categories", 0.0, &c.join(","));
    }
    if !handled.is_empty() {
        let mails = st.all::<service::StoredEmail>("email", 5000);
        for (key, on) in handled {
            for e in mails.iter().filter(|e| sync::mail_key(&e.from_address, &e.subject) == key) {
                if on { let _ = st.put("handledThread", &e.thread_id, now_ts() as f64, &e.thread_id); } else { let _ = st.delete("handledThread", &e.thread_id); }
            }
        }
    }
}

fn hello(st: &Store, state: State) -> Hello { Hello { device: device_id(st), name: device_name(st), state, setup_token: host().want.clone(), setup: None } }

/// What a new device needs to skip setup. Same format as Sources/EverydayCore/Sync/SyncSetup.swift.
fn export_setup(st: &Store, secrets: &HashMap<String, String>) -> Value {
    let cats: Vec<String> = pref(st, "categories").split(',').filter(|c| !c.is_empty()).map(String::from).collect();
    let mut accounts = vec![];
    if let Some(a) = account(st) {
        if let Some(pw) = secrets.get(&secrets::password_key(&a.email)) {
            accounts.push(json!({ "email": a.email, "username": a.email, "presetID": "custom", "imapHost": a.imap_host, "imapPort": a.imap_port, "smtpHost": a.smtp_host, "smtpPort": a.smtp_port,
                "smtpSecurity": if a.smtp_port == 587 { "starttls" } else { "ssl" }, "password": pw }));
        }
    }
    let mut keys = serde_json::Map::new();
    if let Some(k) = secrets.get("ai.gemini").filter(|k| !k.is_empty()) { keys.insert("gemini".into(), json!(k)); }
    json!({ "name": pref(st, "name"), "icsUrl": pref(st, "icsUrl"), "categories": cats, "followedTopics": news::topic_list(&pref(st, "followedTopics")), "mutedTopics": news::topic_list(&pref(st, "mutedTopics")), "briefingInstructions": pref(st, "briefingInstructions"),
            "briefingHour": pref(st, "morningHour").parse::<i64>().unwrap_or(7), "morningOn": pref(st, "morningOn") == "1", "aiProvider": "gemini", "aiKeys": keys, "accounts": accounts })
}

/// Applies a setup bundle: settings into the store, secrets into `secrets` (which the caller saves).
fn apply_setup(st: &Store, b: &Value, secrets: &dyn SecretStore) -> String {
    let put = |k: &str, v: String| { if !v.is_empty() { let _ = st.put("pref", k, 0.0, &v); } };
    put("name", s(b, "name")); put("icsUrl", s(b, "icsUrl")); put("briefingInstructions", s(b, "briefingInstructions"));
    if let Some(c) = b["categories"].as_array() { put("categories", c.iter().filter_map(|x| x.as_str()).collect::<Vec<_>>().join(",")); }
    for k in ["followedTopics", "mutedTopics"] {
        if let Some(v) = b[k].as_array() { put(k, serde_json::to_string(v).unwrap_or_default()); }
    }
    if let Some(h) = b["briefingHour"].as_i64() { put("morningHour", h.to_string()); }
    if let Some(on) = b["morningOn"].as_bool() { put("morningOn", if on { "1".into() } else { "0".into() }); }
    let mut parts = vec![];
    if let Some(k) = b["aiKeys"]["gemini"].as_str().filter(|k| !k.is_empty()) { if secrets.set("ai.gemini", k).is_ok() { parts.push("your Gemini key".to_string()); } }
    // This app holds one mail account; the first one with a password wins.
    if let Some(a) = b["accounts"].as_array().and_then(|l| l.iter().find(|a| a["password"].is_string())) {
        let acct = Account { email: s(a, "email"), imap_host: s(a, "imapHost"), imap_port: a["imapPort"].as_u64().unwrap_or(993) as u16, smtp_host: s(a, "smtpHost"), smtp_port: a["smtpPort"].as_u64().unwrap_or(465) as u16 };
        if secrets.set(&secrets::password_key(&acct.email), &s(a, "password")).is_ok() { let _ = st.put("account", "main", 0.0, &acct); parts.insert(0, acct.email.clone()); }
    }
    let _ = st.put("pref", "onboarded", 0.0, &"1".to_string());
    parts.push("your settings".into());
    format!("Set up {}.", parts.join(", "))
}

/// One exchange with one peer, as the client.
fn exchange(group: &Group, addr: &str) -> Result<(String, usize), String> {
    let (me, mut state) = { let st = st()?; let me = device_id(&st); let s = prepare(&st, &me); (hello(&st, s.clone()), s) };
    let (peer, changed, setup) = group.exchange_full(addr, &me, &mut state).map_err(|e| e.to_string())?;
    if let Some(b) = setup { let mut h = host(); h.want = None; h.received = Some(b); h.changes += 1; }
    let st = st()?; apply(&st, &state, &changed); save_state(&st, &state);
    Ok((peer, changed.len()))
}

fn serve_one(group: &Group, conn: std::net::TcpStream) -> Result<(String, usize), String> {
    let (me, name, mut state) = { let st = st()?; let me = device_id(&st); let s = prepare(&st, &me); (me, device_name(&st), s) };
    let offer = |token: Option<&str>| -> Option<Value> {
        let mut h = host();
        let (t, until, secrets) = { let (t, u) = h.offer.clone()?; (t, u, h.offer_secrets.clone()) };
        if token != Some(t.as_str()) || now_ts() > until { return None; }
        h.offer = None; drop(h);
        Some(export_setup(&*st().ok()?, &secrets))
    };
    let (peer, changed) = group.serve(conn, &me, &name, &mut state, &offer).map_err(|e| e.to_string())?;
    let st = st()?; apply(&st, &state, &changed); save_state(&st, &state);
    Ok((peer, changed.len()))
}

/// Starts listening and advertising, if this device is paired. Safe to call again.
pub fn start(key: Option<String>) -> Result<Value, String> {
    let Some(group) = key.as_deref().and_then(Group::from_key) else { return Ok(json!({ "paired": false })) };
    if host().group.as_ref().map(|g| g.id()) == Some(group.id()) && host().daemon.is_some() { return status(); }
    stop();
    let listener = TcpListener::bind("0.0.0.0:0").map_err(|e| format!("Couldn't open a port for sync: {e}"))?;
    let port = listener.local_addr().map_err(|e| e.to_string())?.port();
    let me = device_id(&*st()?);
    let name = device_name(&*st()?);
    let stop_flag = Arc::new(AtomicBool::new(false));

    // Accept loop.
    { let g = group.clone(); let stop_flag = stop_flag.clone();
      std::thread::spawn(move || for c in listener.incoming() {
          if stop_flag.load(Ordering::Relaxed) { break }
          if let Ok(c) = c { match serve_one(&g, c) {
              Ok((peer, n)) => { let mut h = host(); h.last.insert(peer.clone(), (peer, now_ts())); if n > 0 { h.changes += 1; } }
              Err(e) => host().error = Some(e),
          } }
      }); }

    // Advertise and browse with mDNS.
    let daemon = ServiceDaemon::new().map_err(|e| format!("Couldn't start network discovery: {e}"))?;
    let host_name = format!("everyday-{me}.local.");
    let props = [("group", group.id()), ("device", me.clone()), ("name", name.clone())];
    let info = ServiceInfo::new(sync::SERVICE, &format!("everyday-{me}"), &host_name, "", port, &props[..]).map_err(|e| e.to_string())?.enable_addr_auto();
    daemon.register(info).map_err(|e| format!("Couldn't announce this device: {e}"))?;
    let rx = daemon.browse(sync::SERVICE).map_err(|e| e.to_string())?;
    { let gid = group.id(); let me = me.clone(); let stop_flag = stop_flag.clone();
      std::thread::spawn(move || while let Ok(ev) = rx.recv() {
          if stop_flag.load(Ordering::Relaxed) { break }
          if let ServiceEvent::ServiceResolved(i) = ev {
              let prop = |k: &str| i.get_property_val_str(k).unwrap_or("").to_string();
              if prop("group") != gid || prop("device") == me { continue }
              let Some(ip) = i.get_addresses().iter().find(|a| a.is_ipv4()).or(i.get_addresses().iter().next()).copied() else { continue };
              let addr = if ip.is_ipv6() { format!("[{ip}]:{}", i.get_port()) } else { format!("{ip}:{}", i.get_port()) };
              host().peers.insert(prop("device"), (prop("name"), addr));
              let _ = sync_now();
          }
      }); }

    // Every three minutes while the app runs.
    { let stop_flag = stop_flag.clone();
      std::thread::spawn(move || loop {
          std::thread::sleep(std::time::Duration::from_secs(180));
          if stop_flag.load(Ordering::Relaxed) { break }
          let _ = sync_now();
      }); }

    let mut h = host();
    h.group = Some(group); h.port = port; h.daemon = Some(daemon); h.stop = Some(stop_flag); h.error = None;
    drop(h);
    status()
}

pub fn stop() {
    let mut h = host();
    if let Some(s) = h.stop.take() { s.store(true, Ordering::Relaxed); }
    if let Some(d) = h.daemon.take() { let _ = d.shutdown(); }
    // Wake the accept loop so it sees the stop flag.
    if h.port != 0 { let _ = std::net::TcpStream::connect(("127.0.0.1", h.port)); }
    h.group = None; h.port = 0; h.peers.clear();
}

/// Syncs with every device seen on the network now.
pub fn sync_now() -> Result<Value, String> {
    let (group, peers) = { let h = host(); (h.group.clone(), h.peers.clone()) };
    let Some(group) = group else { return Err("This device isn't paired yet.".into()) };
    let mut done = 0; let mut changed = 0; let mut errors = vec![];
    for (id, (name, addr)) in peers {
        match exchange(&group, &addr) {
            Ok((peer, n)) => { done += 1; changed += n; let mut h = host(); h.last.insert(id, (if peer.is_empty() { name } else { peer }, now_ts())); if n > 0 { h.changes += 1; } }
            Err(e) => errors.push(e),
        }
    }
    host().error = errors.first().cloned();
    Ok(json!({ "devices": done, "changed": changed }))
}

pub fn status() -> Result<Value, String> {
    let h = host();
    let mut seen: Vec<Value> = h.last.values().map(|(n, t)| json!({ "name": n, "at": t })).collect();
    seen.sort_by_key(|v| -v["at"].as_i64().unwrap_or(0));
    let name = device_name(&*st()?);
    Ok(json!({ "paired": h.group.is_some(), "running": h.daemon.is_some(), "name": name, "nearby": h.peers.len(), "devices": seen, "error": h.error, "changes": h.changes, "setupWaiting": h.received.is_some() }))
}

pub fn run(cmd: &str, args: &Value, secrets: &dyn SecretStore) -> Result<Value, String> {
    Ok(match cmd {
        // Shows a QR code with this. Makes a new group the first time.
        // With includeSetup, the code also carries a one-time token that hands over accounts, keys and settings for 10 minutes.
        "syncPairingUri" => {
            let g = match secrets.get(KEY_SECRET).and_then(|k| Group::from_key(&k)) { Some(g) => g, None => { let g = Group::new(); secrets.set(KEY_SECRET, &g.key_b64())?; g } };
            start(Some(g.key_b64()))?;
            if args["includeSetup"].as_bool() == Some(true) {
                let token = format!("{}{}", sync::new_device_id(), sync::new_device_id());
                let mut snap = HashMap::new();
                let email = account(&*st()?).map(|a| a.email);
                for k in ["ai.gemini".to_string()].into_iter().chain(email.map(|e| secrets::password_key(&e))) { if let Some(v) = secrets.get(&k) { snap.insert(k, v); } }
                let mut h = host(); h.offer = Some((token.clone(), now_ts() + 600)); h.offer_secrets = snap;
                json!(format!("{}:{token}", g.pairing_uri()))
            } else { host().offer = None; json!(g.pairing_uri()) }
        }
        // After scanning another device's code.
        "syncJoin" => {
            let uri = s(args, "uri");
            let g = Group::from_pairing_uri(&uri).ok_or("That isn't an everyday. pairing code.")?;
            secrets.set(KEY_SECRET, &g.key_b64())?;
            host().want = Group::setup_token(&uri);
            start(Some(g.key_b64()))?
        }
        // Applies a setup bundle that arrived; its secrets come back to the app to store.
        "syncTakeSetup" => match host().received.take() { Some(b) => json!(apply_setup(&*st()?, &b, secrets)), None => json!(null) },
        "syncStart" => start(secrets.get(KEY_SECRET))?,
        "syncNow" => sync_now()?,
        "syncStatus" => status()?,
        "syncRename" => { let _ = st()?.put("pref", "sync.name", 0.0, &s(args, "name")); stop(); start(secrets.get(KEY_SECRET))? }
        "syncLeave" => { stop(); secrets.set(KEY_SECRET, "")?; /* empty, not deleted, so Android sees the change */ let _ = st()?.delete("sync", "state"); host().last.clear(); json!(null) }
        _ => return Err(format!("Unknown command: {cmd}")),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prepare_stamps_changes_and_deletions() {
        let st = Store::open(None).unwrap();
        let t = tasks::add_quick(&st, "Call Oscar tomorrow", &Local::now());
        let _ = st.put("pref", "categories", 0.0, &"science,space".to_string());
        let s1 = prepare(&st, "me");
        assert!(s1.records.contains_key(&format!("task:{}", t.id)));
        assert_eq!(s1.live("topic").len(), 2);
        let again = prepare(&st, "me");
        assert_eq!(s1, again, "nothing changed, nothing stamped");
        let _ = st.delete("task", &t.id);
        let s2 = prepare(&st, "me");
        assert!(s2.records[&format!("task:{}", t.id)].del);
    }

    #[test]
    fn apply_writes_tasks_and_topics() {
        let st = Store::open(None).unwrap();
        let mut s = State::default();
        s.set("task:mac-1", json!({"title": "Sign the lease", "due": 1800000000, "priority": "high", "created": 1700000000}), 1, "mac");
        s.set("topic:ai", json!(true), 1, "mac");
        apply(&st, &s, &["task:mac-1".into(), "topic:ai".into()]);
        let t: tasks::Task = st.get("task", "mac-1").unwrap();
        assert_eq!((t.title.as_str(), t.priority.as_str(), t.due), ("Sign the lease", "high", Some(1800000000)));
        assert_eq!(pref(&st, "categories"), "ai");
    }

    #[test]
    fn setup_bundle_round_trips() {
        let a = Store::open(None).unwrap();
        let _ = a.put("account", "main", 0.0, &Account { email: "me@fastmail.com".into(), imap_host: "imap.fastmail.com".into(), imap_port: 993, smtp_host: "smtp.fastmail.com".into(), smtp_port: 465 });
        let _ = a.put("pref", "name", 0.0, &"Xavi".to_string());
        let _ = a.put("pref", "categories", 0.0, &"ai,space".to_string());
        let mut sec = HashMap::new(); sec.insert(secrets::password_key("me@fastmail.com"), "app-pw".to_string()); sec.insert("ai.gemini".into(), "g-key".into());
        let b = export_setup(&a, &sec);
        let fresh = Store::open(None).unwrap(); let out = MemorySecrets::default();
        let msg = apply_setup(&fresh, &b, &out);
        assert!(msg.contains("me@fastmail.com"), "{msg}");
        assert_eq!(out.get("ai.gemini").as_deref(), Some("g-key"));
        assert_eq!(out.get(&secrets::password_key("me@fastmail.com")).as_deref(), Some("app-pw"));
        assert_eq!(pref(&fresh, "name"), "Xavi"); assert_eq!(pref(&fresh, "categories"), "ai,space"); assert_eq!(pref(&fresh, "onboarded"), "1");
    }
}
