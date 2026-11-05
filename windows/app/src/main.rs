//! everyday. for Windows: a thin Tauri shell. All logic lives in everyday-core (ported from the Swift EverydayCore).
//! Safety rules carried over from the Mac app: the AI only returns text; sending, archiving and trashing mail happen only from a button the user pressed.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use chrono::Local;
use everyday_core::{ai, briefing, calendar, chat, interest, schedule, tts, bundler::{self, Category}, mailrules, net, news, secrets::{self, SecretStore}, service, smtp, store::Store, tasks};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Mutex;
use tauri::Manager;

struct App { store: Mutex<Store>, secrets: secrets::OsSecrets }

#[derive(Serialize, Deserialize, Clone)]
struct Account { email: String, imap_host: String, imap_port: u16, smtp_host: String, smtp_port: u16 }
#[derive(Serialize, Deserialize, Clone)]
struct TriageDoc { message_id: String, category: String, priority: u8, summary: String, deadline: Option<String>, needs_reply: bool }

fn cat(s: &str) -> Category { match s { "important" => Category::Important, "needsReply" => Category::NeedsReply, "deadline" => Category::Deadline, "actionItem" => Category::ActionItem, "newsletter" => Category::Newsletter, "promo" => Category::Promo, "spamSuspect" => Category::SpamSuspect, _ => Category::Fyi } }
fn now_ts() -> i64 { Local::now().timestamp() }

fn account(st: &Store) -> Option<Account> { st.get("account", "main") }
fn pref(st: &Store, k: &str) -> String { st.get::<String>("pref", k).unwrap_or_default() }
fn ai_key(a: &App) -> Option<String> { a.secrets.get("ai.gemini").filter(|k| !k.is_empty()) }
fn today() -> String { Local::now().format("%A %-d %B %Y, %H:%M").to_string() }

fn local_rules(st: &Store) -> mailrules::Local {
    let mut l = mailrules::Local::default();
    l.handled = st.all::<String>("handledThread", 5000).into_iter().collect();
    l.snoozed = st.all::<serde_json::Value>("snooze", 2000).into_iter().filter_map(|v| Some((v["thread"].as_str()?.to_string(), v["until"].as_i64()?))).collect();
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

#[derive(Serialize)] struct StateOut { email: Option<String>, has_ai_key: bool }
#[tauri::command] fn app_state(a: tauri::State<App>) -> StateOut { let st = a.store.lock().unwrap(); StateOut { email: account(&st).map(|x| x.email), has_ai_key: ai_key(&a).is_some() } }

#[tauri::command]
fn connect_mail(a: tauri::State<App>, email: String, password: String, imap_host: String, imap_port: u16, smtp_host: String, smtp_port: u16) -> Result<String, String> {
    let pw = secrets::clean_app_password(&password);
    let mut c = net::imap_session(&imap_host, imap_port, &email, &pw).map_err(|e| e.to_string())?;
    let n = c.select("INBOX").map_err(|e| e.to_string())?; c.logout();
    a.secrets.set(&secrets::password_key(&email), &pw)?;
    a.store.lock().unwrap().put("account", "main", 0.0, &Account { email: email.clone(), imap_host, imap_port, smtp_host, smtp_port }).map_err(|e| e.to_string())?;
    Ok(format!("Connected as {email} (mailbox {} ready).", n.0))
}

#[tauri::command]
fn sync_mail(a: tauri::State<App>) -> Result<String, String> {
    let acct = account(&a.store.lock().unwrap()).ok_or("Connect your mail first.")?;
    let pw = a.secrets.get(&secrets::password_key(&acct.email)).ok_or("The saved password is missing. Connect your mail again.")?;
    let mut c = net::imap_session(&acct.imap_host, acct.imap_port, &acct.email, &pw).map_err(|e| e.to_string())?;
    let report = { let st = a.store.lock().unwrap(); service::sync(&mut c, &st, now_ts()).map_err(|e| e.to_string())? }; c.logout();
    let mut note = format!("{} new, {} removed.", report.added, report.removed);
    if let Some(key) = ai_key(&a) {
        let (pending, st_emails): (Vec<service::StoredEmail>, ()) = { let st = a.store.lock().unwrap(); let done: std::collections::HashSet<String> = st.all::<TriageDoc>("triage", 10000).into_iter().map(|t| t.message_id).collect(); (st.all::<service::StoredEmail>("email", 400).into_iter().filter(|m| !done.contains(&m.id)).collect(), ()) };
        let _ = st_emails;
        for batch in pending.chunks(8) {
            let items: Vec<ai::EmailForTriage> = batch.iter().map(|m| ai::EmailForTriage { id: m.id.clone(), from_name: m.from_name.clone(), from_address: m.from_address.clone(), subject: m.subject.clone(), date: String::new(), has_attachments: !m.attachment_names.is_empty(), body: m.body.chars().take(1500).collect() }).collect();
            let req = ai::Request { system: ai::triage_system(&today()), messages: vec![(ai::Role::User, ai::triage_payload(&items))], max_tokens: 2500, temperature: 0.1, json: true };
            let text = ai::complete(ai::Provider::Gemini, "gemini-3.5-flash", &key, "", &req).map_err(|e| e.to_string())?;
            let ids: Vec<String> = batch.iter().map(|m| m.id.clone()).collect();
            let st = a.store.lock().unwrap();
            for t in ai::parse_triage(&text, &ids).map_err(|e| e.to_string())? { let _ = st.put("triage", &t.message_id, t.priority as f64, &TriageDoc { message_id: t.message_id.clone(), category: t.category, priority: t.priority, summary: t.summary, deadline: t.deadline, needs_reply: t.needs_reply }); }
        }
        note.push_str(" Mail sorted.");
    }
    Ok(note)
}

#[derive(Serialize)] struct RowOut { thread_id: String, from: String, from_address: String, subject: String, snippet: String, attention: bool, priority: i32, category: String, count: usize }
#[tauri::command] fn inbox(a: tauri::State<App>) -> Vec<RowOut> {
    let st = a.store.lock().unwrap(); let (stored, rows, _) = all_rows(&st);
    rows.into_iter().map(|r| { let snippet = stored.iter().find(|m| m.id == r.message.id).map(|m| m.snippet.clone()).unwrap_or_default();
        RowOut { attention: mailrules::is_attention(&r), priority: r.triage.as_ref().map_or(-1, |t| t.priority as i32), category: r.triage.as_ref().map_or("unsorted".into(), |t| format!("{:?}", t.category)), thread_id: r.message.thread_id, from: r.message.from_name, from_address: r.message.from_address, subject: r.message.subject, snippet, count: r.thread_count } }).collect()
}

#[tauri::command] fn thread(a: tauri::State<App>, thread_id: String) -> Vec<service::StoredEmail> { let st = a.store.lock().unwrap(); let mut v: Vec<service::StoredEmail> = st.all_where("email", "threadId", &thread_id); v.sort_by_key(|m| m.date); v }

/// "That was me": covers the whole automated sender group, never people.
#[tauri::command] fn mark_handled(a: tauri::State<App>, thread_ids: Vec<String>) -> usize {
    let st = a.store.lock().unwrap(); let (stored, rows, _) = all_rows(&st); let _ = stored;
    let br: Vec<bundler::Row> = rows.iter().map(|r| bundler::Row { thread_id: r.message.thread_id.clone(), from_address: r.message.from_address.clone(), category: r.triage.as_ref().map(|t| t.category) }).collect();
    let ids = bundler::expanded_thread_ids(&thread_ids, &br);
    for id in &ids { let _ = st.put("handledThread", id, now_ts() as f64, id); let _ = st.delete("snooze", id); }
    ids.len()
}
#[tauri::command] fn snooze(a: tauri::State<App>, thread_id: String, hours: i64) { let st = a.store.lock().unwrap(); let until = now_ts() + hours * 3600; let _ = st.put("snooze", &thread_id, until as f64, &serde_json::json!({"thread": thread_id, "until": until})); }
#[tauri::command] fn toggle_vip(a: tauri::State<App>, address: String) -> bool { let st = a.store.lock().unwrap(); let k = address.to_lowercase(); if st.get::<String>("vipSender", &k).is_some() { let _ = st.delete("vipSender", &k); false } else { let _ = st.put("vipSender", &k, now_ts() as f64, &k); true } }

fn move_thread(a: &App, thread_id: &str, trash: bool) -> Result<(), String> {
    let (acct, msgs) = { let st = a.store.lock().unwrap(); (account(&st).ok_or("Connect your mail first.")?, st.all_where::<service::StoredEmail>("email", "threadId", thread_id)) };
    let pw = a.secrets.get(&secrets::password_key(&acct.email)).ok_or("The saved password is missing.")?;
    let mut c = net::imap_session(&acct.imap_host, acct.imap_port, &acct.email, &pw).map_err(|e| e.to_string())?;
    c.select("INBOX").map_err(|e| e.to_string())?; let f = c.folders().map_err(|e| e.to_string())?;
    let dest = if trash { f.trash } else { f.archive }.ok_or("This account has no matching folder to move mail into.")?;
    for m in &msgs { if let Some((_, uid)) = service::parse_id(&m.id) { c.uid_move(uid, &dest).map_err(|e| e.to_string())?; } }
    c.logout();
    let st = a.store.lock().unwrap(); for m in &msgs { let _ = st.delete("email", &m.id); } Ok(())
}
/// Only called from the Archive and Trash buttons.
#[tauri::command] fn archive(a: tauri::State<App>, thread_id: String) -> Result<(), String> { move_thread(&a, &thread_id, false) }
#[tauri::command] fn trash(a: tauri::State<App>, thread_id: String) -> Result<(), String> { move_thread(&a, &thread_id, true) }

/// Only called after the user pressed Send and the 10-second undo window ran out.
#[tauri::command]
fn send_reply(a: tauri::State<App>, thread_id: String, body: String) -> Result<(), String> {
    let (acct, last) = { let st = a.store.lock().unwrap(); let mut v: Vec<service::StoredEmail> = st.all_where("email", "threadId", &thread_id); v.sort_by_key(|m| m.date); (account(&st).ok_or("Connect your mail first.")?, v.pop().ok_or("That conversation is gone.")?) };
    let pw = a.secrets.get(&secrets::password_key(&acct.email)).ok_or("The saved password is missing.")?;
    let msg = smtp::compose_reply(&acct.email, &smtp::ReplyTo { from_name: &last.from_name, from_address: &last.from_address, subject: &last.subject, message_id: "", references: &[] }, &body, &Local::now().to_rfc2822(), &format!("{}", now_ts()));
    net::smtp_send(&acct.smtp_host, acct.smtp_port, acct.smtp_port == 465, &acct.email, &pw, &acct.email, &[smtp::bare_address(&last.from_address)], &msg).map_err(|e| e.to_string())?;
    if let Ok(mut c) = net::imap_session(&acct.imap_host, acct.imap_port, &acct.email, &pw) { if let Ok(f) = c.folders() { if let Some(s) = f.sent { let _ = c.append(&s, "\\Seen", &msg); } } c.logout(); }
    Ok(())
}

const FEEDS: &[(&str, &str, i32)] = &[("BBC World", "https://feeds.bbci.co.uk/news/world/rss.xml", 4), ("ABC News Australia", "https://www.abc.net.au/news/feed/51120/rss.xml", 4), ("Ars Technica", "https://feeds.arstechnica.com/arstechnica/index", 3), ("Hacker News", "https://hnrss.org/frontpage", 3), ("Nature", "https://www.nature.com/nature.rss", 4)];
#[tauri::command] fn news_refresh(a: tauri::State<App>) -> Result<usize, String> {
    let mut count = 0;
    for (name, url, trust) in FEEDS { if let Ok(r) = ureq::get(url).set("User-Agent", "everyday./0.1 (personal feed reader)").timeout(std::time::Duration::from_secs(15)).call() {
        let mut buf = vec![]; use std::io::Read; if r.into_reader().take(4_000_000).read_to_end(&mut buf).is_ok() { let st = a.store.lock().unwrap(); for art in news::parse_feed(&buf, name, *trust, false) { count += 1; let _ = st.put("article", &art.id, art.published as f64, &serde_json::json!({"id": art.id, "title": art.title, "summary": art.summary, "source": art.source, "url": art.url, "published": art.published, "trust": art.trust})); } } } }
    Ok(count)
}
#[derive(Serialize)] struct StoryOut { title: String, source: String, url: String, summary: String, also: usize }
#[tauri::command] fn stories(a: tauri::State<App>) -> Vec<StoryOut> {
    let st = a.store.lock().unwrap();
    let arts: Vec<news::Article> = st.all::<serde_json::Value>("article", 4000).into_iter().filter_map(|v| Some(news::Article { id: v["id"].as_str()?.into(), title: v["title"].as_str()?.into(), summary: v["summary"].as_str().unwrap_or("").into(), source: v["source"].as_str()?.into(), url: v["url"].as_str()?.into(), published: v["published"].as_i64()?, trust: v["trust"].as_i64().unwrap_or(3) as i32, outside_bubble: false })).collect();
    let muted: Vec<String> = pref(&st, "mutedTopics").split(',').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect();
    { let prof = profile(&st); news::stories(arts, now_ts(), &news::Options { muted, limit: 40, ..news::Options::default() }, &|x| prof.score(&[], &x.source, &x.title)) }.into_iter().map(|s| StoryOut { title: s.lead.title, source: s.lead.source, url: s.lead.url, summary: s.lead.summary, also: s.others.len() }).collect()
}

#[tauri::command] fn task_list(a: tauri::State<App>) -> Vec<tasks::Task> { tasks::open(&a.store.lock().unwrap()) }
#[tauri::command] fn add_task(a: tauri::State<App>, input: String) -> tasks::Task { tasks::add_quick(&a.store.lock().unwrap(), &input, &Local::now()) }
#[tauri::command] fn toggle_task(a: tauri::State<App>, id: String) { tasks::toggle(&a.store.lock().unwrap(), &id, &Local::now()); }
#[tauri::command] fn delete_task(a: tauri::State<App>, id: String) { let _ = a.store.lock().unwrap().delete("task", &id); }

#[tauri::command] fn save_ai_key(a: tauri::State<App>, key: String) -> Result<(), String> { a.secrets.set("ai.gemini", key.trim()) }
#[tauri::command] fn ai_test(a: tauri::State<App>) -> Result<String, String> {
    let key = ai_key(&a).ok_or("Add a Gemini key first.")?;
    ai::complete(ai::Provider::Gemini, "gemini-3.5-flash", &key, "", &ai::Request { system: "Reply with the single word: ready".into(), messages: vec![(ai::Role::User, "ping".into())], max_tokens: 20, temperature: 0.0, json: false }).map_err(|e| e.to_string())
}
#[tauri::command] fn make_briefing(a: tauri::State<App>) -> Result<String, String> {
    let key = ai_key(&a).ok_or("Add an AI key in Settings to write briefings.")?;
    let st = a.store.lock().unwrap(); let (_, rows, local) = all_rows(&st);
    let task_lines: Vec<String> = tasks::open(&st).iter().map(|t| t.title.clone()).collect();
    let news_lines: Vec<String> = { let arts: Vec<news::Article> = st.all::<serde_json::Value>("article", 400).into_iter().filter_map(|v| Some(news::Article { id: String::new(), title: v["title"].as_str()?.into(), summary: v["summary"].as_str().unwrap_or("").into(), source: v["source"].as_str()?.into(), url: String::new(), published: v["published"].as_i64()?, trust: 3, outside_bubble: false })).collect(); news::stories(arts, now_ts(), &news::Options { limit: 4, ..news::Options::default() }, &|_| 0.0).into_iter().map(|s| format!("{} ({})", s.lead.title, s.lead.source)).collect() };
    let standing = pref(&st, "briefingInstructions");
    let call = |r: &ai::Request| ai::complete(ai::Provider::Gemini, "gemini-3.5-flash", &key, "", r);
    briefing::generate(&call, &briefing::Inputs { rows: &rows, local: &local, tasks: &task_lines, weather: None, calendar: calendar_line(&st), news: &news_lines, standing_instructions: &standing }, "there", &today()).map_err(|e| e.to_string())
}
#[derive(Serialize)] struct ReplyOut { label: String, kind: String, thread_ids: Vec<String>, text: String }
/// Gemini writes the buttons under the briefing for the situation; "That was me" is guaranteed for open automated notices.
#[tauri::command] fn quick_replies(a: tauri::State<App>, briefing_text: String) -> Result<Vec<ReplyOut>, String> {
    let st = a.store.lock().unwrap(); let (stored, rows, _) = all_rows(&st);
    let attention: Vec<&mailrules::Row> = rows.iter().filter(|r| mailrules::is_attention(r)).take(8).collect();
    if attention.is_empty() { return Ok(vec![]); }
    let automated: Vec<String> = attention.iter().filter(|r| bundler::is_automated(&r.message.from_address, r.triage.as_ref().map(|t| t.category))).map(|r| r.message.id.clone()).collect();
    let list = attention.iter().map(|r| format!("- id {}: {}: {}", r.message.id, r.message.from_name, r.triage.as_ref().map(|t| t.summary.clone()).filter(|s| !s.is_empty()).unwrap_or_else(|| r.message.subject.clone()))).collect::<Vec<_>>().join("\n");
    let valid: Vec<String> = attention.iter().map(|r| r.message.id.clone()).collect();
    let mut replies = Vec::new();
    if let Some(key) = ai_key(&a) {
        let req = ai::Request { system: ai::quick_replies_system(), messages: vec![(ai::Role::User, format!("<data>\nBriefing:\n{}\n\nItems:\n{list}\n</data>", everyday_core::skim::strip(&briefing_text)))], max_tokens: 700, temperature: 0.4, json: true };
        if let Ok(t) = ai::complete(ai::Provider::Gemini, "gemini-3.5-flash", &key, "", &req) { replies = ai::parse_replies(&t, &valid); }
    }
    let replies = ai::with_guaranteed_handled(replies, &automated);
    let thread_of = |id: &String| stored.iter().find(|m| &m.id == id).map(|m| m.thread_id.clone());
    Ok(replies.into_iter().map(|r| ReplyOut { thread_ids: r.ids.iter().filter_map(|i| thread_of(i)).collect(), label: r.label, kind: r.kind, text: r.text }).collect())
}
fn profile(st: &Store) -> interest::Profile { st.get("profile", "interest").unwrap_or_default() }
fn load_articles(st: &Store, limit: usize) -> Vec<news::Article> {
    st.all::<serde_json::Value>("article", limit).into_iter().filter_map(|v| Some(news::Article { id: v["id"].as_str()?.into(), title: v["title"].as_str()?.into(), summary: v["summary"].as_str().unwrap_or("").into(), source: v["source"].as_str()?.into(), url: v["url"].as_str()?.into(), published: v["published"].as_i64()?, trust: v["trust"].as_i64().unwrap_or(3) as i32, outside_bubble: false })).collect()
}

#[derive(Serialize)] struct AskOut { text: String, sources: Vec<SourceOut> }
#[derive(Serialize)] struct SourceOut { tag: String, title: String, kind: &'static str, reference: String }
/// The assistant answers from your mail, tasks and news, cites what it used, and cannot change anything.
#[tauri::command] fn ask(a: tauri::State<App>, question: String, history: Vec<(String, String)>) -> Result<AskOut, String> {
    let key = ai_key(&a).ok_or("Add an AI key in Settings first.")?;
    let (sys, sources, hist) = { let st = a.store.lock().unwrap(); let (_, rows, local) = all_rows(&st);
        let task_lines: Vec<String> = tasks::open(&st).iter().map(|t| t.title.clone()).collect();
        let prof = profile(&st);
        let stories = news::stories(load_articles(&st, 600), now_ts(), &news::Options { limit: 12, ..news::Options::default() }, &|x| prof.score(&[], &x.source, &x.title));
        let news_lines: Vec<(String, String)> = stories.iter().map(|s| (s.lead.url.clone(), format!("{} ({})", s.lead.title, s.lead.source))).collect();
        let (ctx, sources) = chat::build_context(&chat::Context { rows: &rows, local: &local, tasks: &task_lines, news: &news_lines, open_item: "" });
        let hist: Vec<(ai::Role, String)> = history.into_iter().map(|(r, t)| (if r == "user" { ai::Role::User } else { ai::Role::Assistant }, t)).collect();
        (chat::system("there", &today(), &ctx), sources, hist) };
    let reply = ai::complete(ai::Provider::Gemini, "gemini-3.5-flash", &key, "", &chat::request(sys, &hist, &question)).map_err(|e| e.to_string())?;
    let (text, cited) = chat::finish(&reply, &sources);
    Ok(AskOut { text, sources: cited.into_iter().map(|c| SourceOut { tag: c.tag, title: c.title, kind: match c.kind { everyday_core::citations::Kind::Mail => "mail", _ => "news" }, reference: c.reference }).collect() })
}

#[tauri::command] fn swipe_deck(a: tauri::State<App>) -> Vec<StoryOut> {
    let st = a.store.lock().unwrap(); let seen: std::collections::HashSet<String> = st.all::<String>("reacted", 5000).into_iter().collect();
    news::stories(load_articles(&st, 600), now_ts(), &news::Options { limit: 60, include_outside: true, ..news::Options::default() }, &|_| 0.0).into_iter().filter(|s| !seen.contains(&s.lead.url)).take(12).map(|s| StoryOut { title: s.lead.title, source: s.lead.source, url: s.lead.url, summary: s.lead.summary, also: s.others.len() }).collect()
}
/// reaction: 2 love, 1 like, -1 not interested.
#[tauri::command] fn react(a: tauri::State<App>, url: String, title: String, source: String, reaction: f64) {
    let st = a.store.lock().unwrap(); let mut p = profile(&st); p.record(&[], &source, &title, reaction, now_ts()); let _ = st.put("profile", "interest", 0.0, &p); let _ = st.put("reacted", &url, 0.0, &url);
}
#[tauri::command] fn seed_interests(a: tauri::State<App>, categories: Vec<String>) { let st = a.store.lock().unwrap(); let mut p = profile(&st); let c: Vec<&str> = categories.iter().map(String::as_str).collect(); p.seed(&c); let _ = st.put("profile", "interest", 0.0, &p); }
#[tauri::command] fn top_interests(a: tauri::State<App>) -> Vec<(String, f64)> { profile(&a.store.lock().unwrap()).top_interests(6) }

/// Natural voice: returns a base64 WAV. Cached on disk so replays cost nothing.
#[tauri::command] fn speak(app: tauri::AppHandle, a: tauri::State<App>, text: String, voice: String) -> Result<String, String> {
    use base64::Engine; let b64 = base64::engine::general_purpose::STANDARD;
    let key = ai_key(&a).ok_or("Natural voices need a Gemini key.")?;
    let dir = app.path().app_data_dir().map_err(|e| e.to_string())?.join("tts"); std::fs::create_dir_all(&dir).ok();
    let model = "gemini-3.8-flash-tts"; let file = dir.join(tts::cache_key(&text, &voice, model));
    if let Ok(bytes) = std::fs::read(&file) { return Ok(b64.encode(bytes)); }
    let http = ai::Http { url: tts::url(model), headers: vec![("x-goog-api-key".into(), key), ("content-type".into(), "application/json".into())], body: tts::request_body(&text, &voice, "") };
    let (status, body) = ai::send(&http).map_err(|e| e.to_string())?;
    if !(200..300).contains(&status) { return Err(ai::parse_response(ai::Provider::Gemini, status, &body).err().map(|e| e.to_string()).unwrap_or_else(|| "The speech service refused the request.".into())); }
    let wav = tts::wav(&tts::pcm_from_response(&body)?, 24000); let _ = std::fs::write(&file, &wav); Ok(b64.encode(wav))
}
#[tauri::command] fn speech_chunks(text: String) -> Vec<String> { tts::chunks(&everyday_core::skim::plain(&text), 220) }

/// True once a day from the chosen hour: the UI then writes the briefing and shows a notification.
#[tauri::command] fn morning_due(a: tauri::State<App>) -> bool {
    let st = a.store.lock().unwrap(); if pref(&st, "morningOn") != "1" || ai_key(&a).is_none() { return false; }
    let hour: u32 = pref(&st, "morningHour").parse().unwrap_or(7); let now = Local::now();
    if schedule::should_send(&now, hour, &pref(&st, "morningLast")) { let _ = st.put("pref", "morningLast", 0.0, &schedule::day_key(&now)); true } else { false }
}
#[tauri::command] fn briefing_preview(text: String) -> String { everyday_core::skim::preview(&text, 150) }

fn fetch_events(url: &str) -> Result<Vec<calendar::Event>, String> {
    if !url.starts_with("https://") && !url.starts_with("webcal://") { return Err("The calendar link must start with https:// (or webcal://).".into()); }
    let url = url.replacen("webcal://", "https://", 1);
    let text = ureq::get(&url).timeout(std::time::Duration::from_secs(15)).call().map_err(|e| format!("Could not read the calendar: {e}"))?.into_string().map_err(|e| e.to_string())?;
    let now = chrono::Utc::now(); let off = Local::now().offset().local_minus_utc();
    Ok(calendar::parse_ics(&text, now - chrono::Duration::hours(12), now + chrono::Duration::days(7), off))
}
fn calendar_line(st: &Store) -> Option<String> {
    let url = pref(st, "icsUrl"); if url.is_empty() { return None; }
    let ev = fetch_events(&url).ok()?; Some(calendar::summary_line(&ev, chrono::Utc::now(), Local::now().offset().local_minus_utc()))
}
#[derive(Serialize)] struct EventOut { title: String, when: String, location: String }
/// Next week's events from your calendar link (Google, Outlook or iCloud can publish one). Read-only.
#[tauri::command] fn upcoming(a: tauri::State<App>) -> Result<Vec<EventOut>, String> {
    let url = pref(&a.store.lock().unwrap(), "icsUrl"); if url.is_empty() { return Ok(vec![]); }
    let off = chrono::Duration::seconds(Local::now().offset().local_minus_utc() as i64);
    Ok(fetch_events(&url)?.into_iter().take(12).map(|e| EventOut { when: if e.all_day { (e.start + off).format("%a %-d %b, all day").to_string() } else { (e.start + off).format("%a %-d %b, %H:%M").to_string() }, title: e.title, location: e.location }).collect())
}
#[tauri::command] fn set_pref(a: tauri::State<App>, key: String, value: String) { let _ = a.store.lock().unwrap().put("pref", &key, 0.0, &value); }
#[tauri::command] fn get_pref(a: tauri::State<App>, key: String) -> String { pref(&a.store.lock().unwrap(), &key) }

fn main() {
    tauri::Builder::default()
        .setup(|app| {
            let dir = app.path().app_data_dir().expect("app data dir"); std::fs::create_dir_all(&dir).ok();
            let store = Store::open(Some(dir.join("everyday.sqlite").to_str().unwrap())).expect("database");
            app.manage(App { store: Mutex::new(store), secrets: secrets::OsSecrets::new("everyday.") });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![app_state, connect_mail, sync_mail, inbox, thread, mark_handled, snooze, toggle_vip, archive, trash, send_reply, news_refresh, stories, task_list, add_task, toggle_task, delete_task, save_ai_key, ai_test, make_briefing, upcoming, quick_replies, ask, swipe_deck, react, seed_interests, top_interests, speak, speech_chunks, morning_due, briefing_preview, set_pref, get_pref])
        .run(tauri::generate_context!())
        .expect("error while running everyday.");
}
