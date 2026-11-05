//! everyday. for Android: the same commands as the Windows app, behind one JSON call.
//! Kotlin calls `Core.call(command, argsJson)` and gets `{"ok": value}` or `{"err": "message"}` back.
//! Secrets stay in the Android Keystore on the Kotlin side: each call passes the ones it may need in `args._secrets`,
//! and any secret a command saves comes back in `secrets` for Kotlin to store. Nothing secret is written to the database.
//! Safety rules carried over from the Mac app: the AI only returns text; sending, archiving and trashing mail happen
//! only from a button the user pressed.

use chrono::Local;
use everyday_core::{ai, briefing, bundler::{self, Category}, calendar, chat, interest, mailrules, net, news, schedule, secrets::{self, MemorySecrets, SecretStore}, service, skim, smtp, store::Store, tasks, tts};
use once_cell::sync::OnceCell;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Mutex;

static STORE: OnceCell<Mutex<Store>> = OnceCell::new();
static DIR: OnceCell<String> = OnceCell::new();

const MODEL: &str = "gemini-3.5-flash";

#[derive(Serialize, Deserialize, Clone)]
struct Account { email: String, imap_host: String, imap_port: u16, smtp_host: String, smtp_port: u16 }
#[derive(Serialize, Deserialize, Clone)]
struct TriageDoc { message_id: String, category: String, priority: u8, summary: String, deadline: Option<String>, needs_reply: bool }

/// Opens the database in the app's private files folder. Safe to call more than once.
pub fn init(dir: &str) -> Result<(), String> {
    if STORE.get().is_some() { return Ok(()); }
    std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    let store = Store::open(Some(&format!("{dir}/everyday.sqlite"))).map_err(|e| e.to_string())?;
    let _ = DIR.set(dir.to_string());
    let _ = STORE.set(Mutex::new(store));
    Ok(())
}

fn st() -> Result<std::sync::MutexGuard<'static, Store>, String> { Ok(STORE.get().ok_or("The app hasn't opened its storage yet.")?.lock().unwrap_or_else(|e| e.into_inner())) }
fn cat(s: &str) -> Category { match s { "important" => Category::Important, "needsReply" => Category::NeedsReply, "deadline" => Category::Deadline, "actionItem" => Category::ActionItem, "newsletter" => Category::Newsletter, "promo" => Category::Promo, "spamSuspect" => Category::SpamSuspect, _ => Category::Fyi } }
fn now_ts() -> i64 { Local::now().timestamp() }
fn today() -> String { Local::now().format("%A %-d %B %Y, %H:%M").to_string() }
fn account(st: &Store) -> Option<Account> { st.get("account", "main") }
fn pref(st: &Store, k: &str) -> String { st.get::<String>("pref", k).unwrap_or_default() }
fn s(v: &Value, k: &str) -> String { v[k].as_str().unwrap_or_default().to_string() }

fn local_rules(st: &Store) -> mailrules::Local {
    let mut l = mailrules::Local::default();
    l.handled = st.all::<String>("handledThread", 5000).into_iter().collect();
    l.snoozed = st.all::<Value>("snooze", 2000).into_iter().filter_map(|v| Some((v["thread"].as_str()?.to_string(), v["until"].as_i64()?))).collect();
    l.vips = st.all::<String>("vipSender", 500).into_iter().collect();
    l
}
fn all_rows(st: &Store) -> (Vec<service::StoredEmail>, Vec<mailrules::Row>, mailrules::Local) {
    let stored: Vec<service::StoredEmail> = st.all("email", 5000);
    let triage: HashMap<String, mailrules::Triage> = st.all::<TriageDoc>("triage", 10000).into_iter().map(|t| (t.message_id.clone(), mailrules::Triage { message_id: t.message_id, category: cat(&t.category), priority: t.priority, summary: t.summary, deadline: None, needs_reply: t.needs_reply })).collect();
    let local = local_rules(st);
    let rows = mailrules::rows(&stored.iter().map(|m| m.to_email()).collect::<Vec<_>>(), &triage, &local, now_ts());
    (stored, rows, local)
}
fn profile(st: &Store) -> interest::Profile { st.get("profile", "interest").unwrap_or_default() }
fn load_articles(st: &Store, limit: usize) -> Vec<news::Article> {
    st.all::<Value>("article", limit).into_iter().filter_map(|v| Some(news::Article { id: v["id"].as_str()?.into(), title: v["title"].as_str()?.into(), summary: v["summary"].as_str().unwrap_or("").into(), source: v["source"].as_str()?.into(), url: v["url"].as_str()?.into(), published: v["published"].as_i64()?, trust: v["trust"].as_i64().unwrap_or(3) as i32, outside_bubble: false })).collect()
}
fn ai_call(key: &str, r: &ai::Request) -> Result<String, String> { ai::complete(ai::Provider::Gemini, MODEL, key, "", r).map_err(|e| e.to_string()) }

/// Runs one command. `secrets` holds what Kotlin passed in; anything set during the call is returned to be saved.
pub fn run(cmd: &str, args: &Value, secrets: &dyn SecretStore) -> Result<Value, String> {
    let key = || secrets.get("ai.gemini").filter(|k| !k.is_empty());
    let need_key = || key().ok_or_else(|| "Add a Gemini key in Settings first.".to_string());
    let password = |acct: &Account| secrets.get(&secrets::password_key(&acct.email)).ok_or_else(|| "The saved password is missing. Connect your mail again.".to_string());
    Ok(match cmd {
        "state" => { let st = st()?; json!({ "email": account(&st).map(|a| a.email), "hasAiKey": key().is_some(), "name": pref(&st, "name") }) }

        "connectMail" => {
            let email = s(args, "email"); let pw = secrets::clean_app_password(&s(args, "password"));
            let (ih, ip, sh, sp) = (s(args, "imapHost"), args["imapPort"].as_u64().unwrap_or(993) as u16, s(args, "smtpHost"), args["smtpPort"].as_u64().unwrap_or(465) as u16);
            let mut c = net::imap_session(&ih, ip, &email, &pw).map_err(|e| e.to_string())?;
            c.select("INBOX").map_err(|e| e.to_string())?; c.logout();
            secrets.set(&secrets::password_key(&email), &pw)?;
            st()?.put("account", "main", 0.0, &Account { email: email.clone(), imap_host: ih, imap_port: ip, smtp_host: sh, smtp_port: sp }).map_err(|e| e.to_string())?;
            json!(format!("Connected as {email}."))
        }
        "disconnectMail" => { let st = st()?; let _ = st.delete("account", "main"); let _ = st.delete_all("email"); let _ = st.delete_all("triage"); json!(null) }

        "syncMail" => {
            let acct = account(&*st()?).ok_or("Connect your mail first.")?;
            let pw = password(&acct)?;
            let mut c = net::imap_session(&acct.imap_host, acct.imap_port, &acct.email, &pw).map_err(|e| e.to_string())?;
            let report = { let st = st()?; service::sync(&mut c, &st, now_ts()).map_err(|e| e.to_string())? }; c.logout();
            let mut note = format!("{} new, {} removed.", report.added, report.removed);
            if let Some(k) = key() {
                let pending: Vec<service::StoredEmail> = { let st = st()?; let done: std::collections::HashSet<String> = st.all::<TriageDoc>("triage", 10000).into_iter().map(|t| t.message_id).collect(); st.all::<service::StoredEmail>("email", 400).into_iter().filter(|m| !done.contains(&m.id)).collect() };
                for batch in pending.chunks(8) {
                    let items: Vec<ai::EmailForTriage> = batch.iter().map(|m| ai::EmailForTriage { id: m.id.clone(), from_name: m.from_name.clone(), from_address: m.from_address.clone(), subject: m.subject.clone(), date: String::new(), has_attachments: !m.attachment_names.is_empty(), body: m.body.chars().take(1500).collect() }).collect();
                    let text = ai_call(&k, &ai::Request { system: ai::triage_system(&today()), messages: vec![(ai::Role::User, ai::triage_payload(&items))], max_tokens: 2500, temperature: 0.1, json: true })?;
                    let ids: Vec<String> = batch.iter().map(|m| m.id.clone()).collect();
                    let st = st()?;
                    for t in ai::parse_triage(&text, &ids).map_err(|e| e.to_string())? { let _ = st.put("triage", &t.message_id, t.priority as f64, &TriageDoc { message_id: t.message_id.clone(), category: t.category, priority: t.priority, summary: t.summary, deadline: t.deadline, needs_reply: t.needs_reply }); }
                }
                note.push_str(" Mail sorted.");
            }
            json!(note)
        }

        "inbox" => {
            let st = st()?; let (stored, rows, _) = all_rows(&st);
            json!(rows.into_iter().map(|r| {
                let m = stored.iter().find(|m| m.id == r.message.id);
                let security = m.map_or(false, |m| bundler::is_automated(&m.from_address, r.triage.as_ref().map(|t| t.category)) && is_security(&m.subject));
                json!({ "threadId": r.message.thread_id, "from": r.message.from_name, "fromAddress": r.message.from_address, "subject": r.message.subject,
                        "snippet": m.map(|m| skim::preview(&m.snippet, 140)).unwrap_or_default(), "summary": r.triage.as_ref().map(|t| t.summary.clone()).unwrap_or_default(),
                        "attention": mailrules::is_attention(&r), "priority": r.triage.as_ref().map_or(-1, |t| t.priority as i32),
                        "category": r.triage.as_ref().map_or("unsorted".into(), |t| format!("{:?}", t.category)), "count": r.thread_count, "date": r.message.date, "security": security })
            }).collect::<Vec<_>>())
        }
        "thread" => { let st = st()?; let mut v: Vec<service::StoredEmail> = st.all_where("email", "threadId", &s(args, "threadId")); v.sort_by_key(|m| m.date);
            json!(v.into_iter().map(|m| json!({ "id": m.id, "from": m.from_name, "fromAddress": m.from_address, "subject": m.subject, "date": m.date, "body": m.body, "attachments": m.attachment_names })).collect::<Vec<_>>()) }
        // "That was me": covers the whole automated sender group, never people.
        "markHandled" => {
            let st = st()?; let (_, rows, _) = all_rows(&st);
            let ids_in: Vec<String> = args["threadIds"].as_array().map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default();
            let br: Vec<bundler::Row> = rows.iter().map(|r| bundler::Row { thread_id: r.message.thread_id.clone(), from_address: r.message.from_address.clone(), category: r.triage.as_ref().map(|t| t.category) }).collect();
            let ids = bundler::expanded_thread_ids(&ids_in, &br);
            for id in &ids { let _ = st.put("handledThread", id, now_ts() as f64, id); let _ = st.delete("snooze", id); }
            json!(ids.len())
        }
        "snooze" => { let st = st()?; let t = s(args, "threadId"); let until = now_ts() + args["hours"].as_i64().unwrap_or(3) * 3600; let _ = st.put("snooze", &t, until as f64, &json!({"thread": t, "until": until})); json!(null) }
        "archive" | "trash" => { move_thread(&s(args, "threadId"), cmd == "trash", &password)?; json!(null) }
        // Only called after the user pressed Send and the undo window ran out.
        "sendReply" => {
            let thread_id = s(args, "threadId"); let body = s(args, "body");
            let (acct, last) = { let st = st()?; let mut v: Vec<service::StoredEmail> = st.all_where("email", "threadId", &thread_id); v.sort_by_key(|m| m.date); (account(&st).ok_or("Connect your mail first.")?, v.pop().ok_or("That conversation is gone.")?) };
            let pw = password(&acct)?;
            let msg = smtp::compose_reply(&acct.email, &smtp::ReplyTo { from_name: &last.from_name, from_address: &last.from_address, subject: &last.subject, message_id: "", references: &[] }, &body, &Local::now().to_rfc2822(), &format!("{}", now_ts()));
            net::smtp_send(&acct.smtp_host, acct.smtp_port, acct.smtp_port == 465, &acct.email, &pw, &acct.email, &[smtp::bare_address(&last.from_address)], &msg).map_err(|e| e.to_string())?;
            if let Ok(mut c) = net::imap_session(&acct.imap_host, acct.imap_port, &acct.email, &pw) { if let Ok(f) = c.folders() { if let Some(s) = f.sent { let _ = c.append(&s, "\\Seen", &msg); } } c.logout(); }
            json!(null)
        }

        "newsRefresh" => {
            let mut count = 0;
            for (name, url, trust) in FEEDS {
                if let Ok(r) = ureq::get(url).set("User-Agent", "everyday./0.1 (personal feed reader)").timeout(std::time::Duration::from_secs(15)).call() {
                    let mut buf = vec![]; use std::io::Read;
                    if r.into_reader().take(4_000_000).read_to_end(&mut buf).is_ok() { let st = st()?; for art in news::parse_feed(&buf, name, *trust, false) { count += 1; let _ = st.put("article", &art.id, art.published as f64, &json!({"id": art.id, "title": art.title, "summary": art.summary, "source": art.source, "url": art.url, "published": art.published, "trust": art.trust})); } }
                }
            }
            json!(count)
        }
        "stories" => {
            let st = st()?; let prof = profile(&st);
            let muted: Vec<String> = pref(&st, "mutedTopics").split(',').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect();
            json!(news::stories(load_articles(&st, 4000), now_ts(), &news::Options { muted, limit: 40, ..news::Options::default() }, &|x| prof.score(&[], &x.source, &x.title)).into_iter().map(|s| story(s)).collect::<Vec<_>>())
        }
        "swipeDeck" => {
            let st = st()?; let seen: std::collections::HashSet<String> = st.all::<String>("reacted", 5000).into_iter().collect();
            json!(news::stories(load_articles(&st, 600), now_ts(), &news::Options { limit: 60, include_outside: true, ..news::Options::default() }, &|_| 0.0).into_iter().filter(|s| !seen.contains(&s.lead.url)).take(12).map(|s| story(s)).collect::<Vec<_>>())
        }
        // reaction: 2 love, 1 like, -1 not interested.
        "react" => { let st = st()?; let mut p = profile(&st); p.record(&[], &s(args, "source"), &s(args, "title"), args["reaction"].as_f64().unwrap_or(1.0), now_ts()); let _ = st.put("profile", "interest", 0.0, &p); let _ = st.put("reacted", &s(args, "url"), 0.0, &s(args, "url")); json!(null) }
        "seedInterests" => { let st = st()?; let mut p = profile(&st); let c: Vec<String> = args["categories"].as_array().map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default(); p.seed(&c.iter().map(String::as_str).collect::<Vec<_>>()); let _ = st.put("profile", "interest", 0.0, &p); json!(null) }

        "topInterests" => json!(profile(&*st()?).top_interests(8).into_iter().filter(|(_, w)| *w > 0.0).map(|(n, _)| n).collect::<Vec<_>>()),
        "resetInterests" => { let st = st()?; let _ = st.delete("profile", "interest"); let _ = st.delete_all("reacted"); json!(null) }
        "tasks" => json!(tasks::open(&*st()?)),
        "addTask" => json!(tasks::add_quick(&*st()?, &s(args, "input"), &Local::now())),
        "toggleTask" => { tasks::toggle(&*st()?, &s(args, "id"), &Local::now()); json!(null) }
        "deleteTask" => { let _ = st()?.delete("task", &s(args, "id")); json!(null) }

        "saveAiKey" => { secrets.set("ai.gemini", s(args, "key").trim())?; json!(null) }
        "aiTest" => json!(ai_call(&need_key()?, &ai::Request { system: "Reply with the single word: ready".into(), messages: vec![(ai::Role::User, "ping".into())], max_tokens: 20, temperature: 0.0, json: false })?),
        "briefing" => {
            let k = need_key()?;
            let (rows, local, task_lines, news_lines, standing, cal, name) = {
                let st = st()?; let (_, rows, local) = all_rows(&st);
                let tl: Vec<String> = tasks::open(&st).iter().map(|t| t.title.clone()).collect();
                let nl: Vec<String> = news::stories(load_articles(&st, 400), now_ts(), &news::Options { limit: 4, ..news::Options::default() }, &|_| 0.0).into_iter().map(|s| format!("{} ({})", s.lead.title, s.lead.source)).collect();
                (rows, local, tl, nl, pref(&st, "briefingInstructions"), pref(&st, "icsUrl"), pref(&st, "name"))
            };
            let cal_line = if cal.is_empty() { None } else { fetch_events(&cal).ok().map(|ev| calendar::summary_line(&ev, chrono::Utc::now(), Local::now().offset().local_minus_utc())) };
            let call = |r: &ai::Request| ai::complete(ai::Provider::Gemini, MODEL, &k, "", r);
            let text = briefing::generate(&call, &briefing::Inputs { rows: &rows, local: &local, tasks: &task_lines, weather: None, calendar: cal_line, news: &news_lines, standing_instructions: &standing }, if name.is_empty() { "there" } else { &name }, &today()).map_err(|e| e.to_string())?;
            let st = st()?; let _ = st.put("briefing", "latest", now_ts() as f64, &json!({"text": text, "at": now_ts()}));
            json!(text)
        }
        "lastBriefing" => st()?.get::<Value>("briefing", "latest").unwrap_or(Value::Null),
        "quickReplies" => {
            let (stored, attention, valid, automated, list) = {
                let st = st()?; let (stored, rows, _) = all_rows(&st);
                let att: Vec<mailrules::Row> = rows.into_iter().filter(|r| mailrules::is_attention(r)).take(8).collect();
                let automated: Vec<String> = att.iter().filter(|r| bundler::is_automated(&r.message.from_address, r.triage.as_ref().map(|t| t.category))).map(|r| r.message.id.clone()).collect();
                let list = att.iter().map(|r| format!("- id {}: {}: {}", r.message.id, r.message.from_name, r.triage.as_ref().map(|t| t.summary.clone()).filter(|s| !s.is_empty()).unwrap_or_else(|| r.message.subject.clone()))).collect::<Vec<_>>().join("\n");
                let valid: Vec<String> = att.iter().map(|r| r.message.id.clone()).collect();
                (stored, att, valid, automated, list)
            };
            if attention.is_empty() { return Ok(json!([])); }
            let mut replies = Vec::new();
            if let Some(k) = key() {
                let req = ai::Request { system: ai::quick_replies_system(), messages: vec![(ai::Role::User, format!("<data>\nBriefing:\n{}\n\nItems:\n{list}\n</data>", skim::strip(&s(args, "briefing"))))], max_tokens: 700, temperature: 0.4, json: true };
                if let Ok(t) = ai_call(&k, &req) { replies = ai::parse_replies(&t, &valid); }
            }
            let thread_of = |id: &String| stored.iter().find(|m| &m.id == id).map(|m| m.thread_id.clone());
            json!(ai::with_guaranteed_handled(replies, &automated).into_iter().map(|r| json!({ "threadIds": r.ids.iter().filter_map(|i| thread_of(i)).collect::<Vec<_>>(), "label": r.label, "kind": r.kind, "text": r.text })).collect::<Vec<_>>())
        }
        // The assistant answers from your mail, tasks and news, cites what it used, and cannot change anything.
        "ask" => {
            let k = need_key()?;
            let hist: Vec<(ai::Role, String)> = args["history"].as_array().map(|a| a.iter().filter_map(|x| Some((if x["role"].as_str()? == "user" { ai::Role::User } else { ai::Role::Assistant }, x["text"].as_str()?.to_string()))).collect()).unwrap_or_default();
            let (sys, sources) = {
                let st = st()?; let (_, rows, local) = all_rows(&st);
                let tl: Vec<String> = tasks::open(&st).iter().map(|t| t.title.clone()).collect();
                let prof = profile(&st);
                let nl: Vec<(String, String)> = news::stories(load_articles(&st, 600), now_ts(), &news::Options { limit: 12, ..news::Options::default() }, &|x| prof.score(&[], &x.source, &x.title)).iter().map(|s| (s.lead.url.clone(), format!("{} ({})", s.lead.title, s.lead.source))).collect();
                let (ctx, sources) = chat::build_context(&chat::Context { rows: &rows, local: &local, tasks: &tl, news: &nl, open_item: "" });
                let name = pref(&st, "name");
                (chat::system(if name.is_empty() { "there" } else { &name }, &today(), &ctx), sources)
            };
            let reply = ai_call(&k, &chat::request(sys, &hist, &s(args, "question")))?;
            let (text, cited) = chat::finish(&reply, &sources);
            json!({ "text": text, "sources": cited.into_iter().map(|c| json!({ "tag": c.tag, "title": c.title, "reference": c.reference })).collect::<Vec<_>>() })
        }
        // Natural voice: a WAV file cached in the app folder so replays cost nothing. Returns its path.
        "speak" => {
            let k = key().ok_or("Natural voices need a Gemini key.")?;
            let text = skim::plain(&s(args, "text")); let voice = { let v = s(args, "voice"); if v.is_empty() { "Kore".to_string() } else { v } };
            let dir = format!("{}/tts", DIR.get().ok_or("No storage.")?); std::fs::create_dir_all(&dir).ok();
            let model = "gemini-3.8-flash-tts"; let file = format!("{dir}/{}", tts::cache_key(&text, &voice, model));
            if std::path::Path::new(&file).exists() { return Ok(json!(file)); }
            let http = ai::Http { url: tts::url(model), headers: vec![("x-goog-api-key".into(), k), ("content-type".into(), "application/json".into())], body: tts::request_body(&text, &voice, "") };
            let (status, body) = ai::send(&http).map_err(|e| e.to_string())?;
            if !(200..300).contains(&status) { return Err(ai::parse_response(ai::Provider::Gemini, status, &body).err().map(|e| e.to_string()).unwrap_or_else(|| "The speech service refused the request.".into())); }
            std::fs::write(&file, tts::wav(&tts::pcm_from_response(&body)?, 24000)).map_err(|e| e.to_string())?;
            json!(file)
        }
        "morningDue" => {
            let st = st()?; if pref(&st, "morningOn") != "1" || key().is_none() { return Ok(json!(false)); }
            let hour: u32 = pref(&st, "morningHour").parse().unwrap_or(7); let now = Local::now();
            if schedule::should_send(&now, hour, &pref(&st, "morningLast")) { let _ = st.put("pref", "morningLast", 0.0, &schedule::day_key(&now)); json!(true) } else { json!(false) }
        }
        "preview" => json!(skim::preview(&s(args, "text"), 150)),
        "upcoming" => {
            let url = pref(&*st()?, "icsUrl"); if url.is_empty() { return Ok(json!([])); }
            let off = chrono::Duration::seconds(Local::now().offset().local_minus_utc() as i64);
            json!(fetch_events(&url)?.into_iter().take(12).map(|e| json!({ "when": if e.all_day { (e.start + off).format("%a %-d %b, all day").to_string() } else { (e.start + off).format("%a %-d %b, %H:%M").to_string() }, "title": e.title, "location": e.location, "start": e.start.timestamp(), "allDay": e.all_day })).collect::<Vec<_>>())
        }
        "setPref" => { let _ = st()?.put("pref", &s(args, "key"), 0.0, &s(args, "value")); json!(null) }
        "getPref" => json!(pref(&*st()?, &s(args, "key"))),
        other => return Err(format!("Unknown command: {other}")),
    })
}

fn is_security(subject: &str) -> bool {
    let s = subject.to_lowercase();
    ["sign-in", "sign in", "signed in", "login", "log in", "new device", "security alert", "verification code", "password", "passkey", "2-step", "two-factor"].iter().any(|k| s.contains(k))
}

fn story(s: news::Story) -> Value { json!({ "title": s.lead.title, "source": s.lead.source, "url": s.lead.url, "summary": s.lead.summary, "published": s.lead.published, "also": s.others.len() }) }

fn move_thread(thread_id: &str, trash: bool, password: &dyn Fn(&Account) -> Result<String, String>) -> Result<(), String> {
    let (acct, msgs) = { let st = st()?; (account(&st).ok_or("Connect your mail first.")?, st.all_where::<service::StoredEmail>("email", "threadId", thread_id)) };
    let pw = password(&acct)?;
    let mut c = net::imap_session(&acct.imap_host, acct.imap_port, &acct.email, &pw).map_err(|e| e.to_string())?;
    c.select("INBOX").map_err(|e| e.to_string())?; let f = c.folders().map_err(|e| e.to_string())?;
    let dest = if trash { f.trash } else { f.archive }.ok_or("This account has no matching folder to move mail into.")?;
    for m in &msgs { if let Some((_, uid)) = service::parse_id(&m.id) { c.uid_move(uid, &dest).map_err(|e| e.to_string())?; } }
    c.logout();
    let st = st()?; for m in &msgs { let _ = st.delete("email", &m.id); } Ok(())
}

const FEEDS: &[(&str, &str, i32)] = &[("BBC World", "https://feeds.bbci.co.uk/news/world/rss.xml", 4), ("ABC News Australia", "https://www.abc.net.au/news/feed/51120/rss.xml", 4), ("Ars Technica", "https://feeds.arstechnica.com/arstechnica/index", 3), ("Hacker News", "https://hnrss.org/frontpage", 3), ("Nature", "https://www.nature.com/nature.rss", 4), ("The Decoder", "https://the-decoder.com/feed/", 3), ("Hugging Face", "https://huggingface.co/blog/feed.xml", 3)];

fn fetch_events(url: &str) -> Result<Vec<calendar::Event>, String> {
    if !url.starts_with("https://") && !url.starts_with("webcal://") { return Err("The calendar link must start with https:// (or webcal://).".into()); }
    let url = url.replacen("webcal://", "https://", 1);
    let text = ureq::get(&url).timeout(std::time::Duration::from_secs(15)).call().map_err(|e| format!("Could not read the calendar: {e}"))?.into_string().map_err(|e| e.to_string())?;
    let now = chrono::Utc::now(); let off = Local::now().offset().local_minus_utc();
    Ok(calendar::parse_ics(&text, now - chrono::Duration::hours(12), now + chrono::Duration::days(7), off))
}

/// The whole round trip as JSON text: what Kotlin sees.
pub fn call_json(cmd: &str, args: &str) -> String {
    let args: Value = serde_json::from_str(args).unwrap_or(json!({}));
    let secrets = MemorySecrets::default();
    let mut before = HashMap::new();
    if let Some(m) = args["_secrets"].as_object() { for (k, v) in m { if let Some(v) = v.as_str() { let _ = secrets.set(k, v); before.insert(k.clone(), v.to_string()); } } }
    let out = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| run(cmd, &args, &secrets))).unwrap_or_else(|_| Err("Something went wrong inside everyday.".into()));
    // Hand back only secrets the command created or changed.
    let changed: serde_json::Map<String, Value> = secrets.entries().into_iter().filter(|(k, v)| before.get(k) != Some(v)).map(|(k, v)| (k, json!(v))).collect();
    match out { Ok(v) => json!({ "ok": v, "secrets": changed }), Err(e) => json!({ "err": e, "secrets": changed }) }.to_string()
}

#[cfg(target_os = "android")]
mod android {
    use jni::objects::{JClass, JString};
    use jni::sys::jstring;
    use jni::JNIEnv;

    fn text(env: &mut JNIEnv, s: &JString) -> String { env.get_string(s).map(|s| s.into()).unwrap_or_default() }

    #[no_mangle]
    pub extern "system" fn Java_app_everyday_android_Core_init<'a>(mut env: JNIEnv<'a>, _c: JClass<'a>, dir: JString<'a>) -> jstring {
        let d = text(&mut env, &dir);
        let r = super::init(&d).err().unwrap_or_default();
        env.new_string(r).map(|s| s.into_raw()).unwrap_or(std::ptr::null_mut())
    }

    #[no_mangle]
    pub extern "system" fn Java_app_everyday_android_Core_call<'a>(mut env: JNIEnv<'a>, _c: JClass<'a>, cmd: JString<'a>, args: JString<'a>) -> jstring {
        let (c, a) = (text(&mut env, &cmd), text(&mut env, &args));
        let out = super::call_json(&c, &a);
        env.new_string(out).map(|s| s.into_raw()).unwrap_or(std::ptr::null_mut())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn round_trip_without_network() {
        let dir = std::env::temp_dir().join(format!("everyday-mobile-{}", std::process::id()));
        init(dir.to_str().unwrap()).unwrap();
        let v: Value = serde_json::from_str(&call_json("state", "{}")).unwrap();
        assert_eq!(v["ok"]["email"], Value::Null);
        let v: Value = serde_json::from_str(&call_json("addTask", r#"{"input":"Pay rent tomorrow"}"#)).unwrap();
        assert!(v["ok"]["title"].as_str().unwrap().contains("rent"));
        let v: Value = serde_json::from_str(&call_json("saveAiKey", r#"{"key":" abc "}"#)).unwrap();
        assert_eq!(v["secrets"]["ai.gemini"], "abc");
        let v: Value = serde_json::from_str(&call_json("state", r#"{"_secrets":{"ai.gemini":"abc"}}"#)).unwrap();
        assert_eq!(v["ok"]["hasAiKey"], true);
        assert!(v["secrets"].as_object().unwrap().is_empty());
        let v: Value = serde_json::from_str(&call_json("nope", "{}")).unwrap();
        assert!(v["err"].as_str().unwrap().contains("Unknown"));
        assert!(is_security("New sign-in to your Google Account"));
        assert!(!is_security("Your order has shipped"));
    }
}
