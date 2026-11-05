//! everyday. for Windows: a native Slint interface (no WebView) over the shared command layer in `everyday-mobile`,
//! the same one the Android app uses. Secrets live in Windows Credential Manager (the Keychain when run on a Mac).
//! Safety rules carried over from the Mac app: the AI only returns text; sending, archiving and trashing mail happen
//! only from a button the user pressed.
#![cfg_attr(all(not(debug_assertions), windows), windows_subsystem = "windows")]

use everyday_core::{secrets::{OsSecrets, SecretStore}, skim};
use regex::Regex;
use serde_json::{json, Value};
use slint::{ComponentHandle, ModelRc, SharedString, Timer, TimerMode, VecModel};
use std::rc::Rc;
use std::sync::Arc;
use std::time::Duration;

slint::include_modules!();

type Secrets = Arc<dyn SecretStore>;

thread_local! {
    /// UI-thread callbacks waiting for a worker's result, by ticket. They hold `Rc`s, so they never cross threads.
    static WAITING: std::cell::RefCell<std::collections::HashMap<u64, Box<dyn FnOnce(AppWindow, Box<dyn std::any::Any + Send>)>>> = Default::default();
    static NEXT: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
}

/// Runs a core command on a worker thread, then hands the result to `done` on the UI thread.
fn bg<T: Send + 'static>(ui: &AppWindow, secrets: &Secrets, work: impl FnOnce(&dyn SecretStore) -> T + Send + 'static, done: impl FnOnce(AppWindow, T) + 'static) {
    let ticket = NEXT.with(|n| { let t = n.get(); n.set(t + 1); t });
    WAITING.with(|w| w.borrow_mut().insert(ticket, Box::new(move |ui, out| { if let Ok(v) = out.downcast::<T>() { done(ui, *v) } })));
    let weak = ui.as_weak(); let s = secrets.clone();
    std::thread::spawn(move || {
        let out: Box<dyn std::any::Any + Send> = Box::new(work(&*s));
        let _ = weak.upgrade_in_event_loop(move |ui| { if let Some(f) = WAITING.with(|w| w.borrow_mut().remove(&ticket)) { f(ui, out) } });
    });
}

fn run(s: &dyn SecretStore, cmd: &str, args: Value) -> Result<Value, String> { everyday_mobile::run(cmd, &args, s) }

fn model<T: Clone + 'static>(v: Vec<T>) -> ModelRc<T> { ModelRc::from(Rc::new(VecModel::from(v))) }
fn st(v: &Value, k: &str) -> SharedString { v[k].as_str().unwrap_or_default().into() }

/// "2h", "Yesterday", "Tue", "3 Mar".
fn short_time(epoch: i64) -> String {
    use chrono::{Local, TimeZone};
    let Some(t) = Local.timestamp_opt(epoch, 0).single() else { return String::new() };
    let now = Local::now(); let d = (now - t).num_seconds();
    if d < 60 { "now".into() } else if d < 3600 { format!("{}m", d / 60) }
    else if t.date_naive() == now.date_naive() { t.format("%-H:%M").to_string() }
    else if d < 86400 * 2 { "Yesterday".into() } else if d < 86400 * 6 { t.format("%a").to_string() } else { t.format("%-d %b").to_string() }
}

/// Readable email text, as MailText on the Mac: "Set up a passkey <https://…>" becomes "Set up a passkey", bare links become their site name.
fn readable(body: &str) -> String {
    let labelled = Regex::new(r"([^\n<>]*?[^\s<>|])\s*<<?(https?://[^\s<>]+)>>?").unwrap();
    let bare = Regex::new(r"https?://[^\s<>()]+").unwrap();
    let text = body.replace("\r\n", "\n");
    let text: String = text.lines().filter(|l| { let t = l.trim(); !(t.starts_with("<http") && t.ends_with('>')) }).collect::<Vec<_>>().join("\n");
    let text = labelled.replace_all(&text, "$1");
    let text = bare.replace_all(&text, |c: &regex::Captures| url_host(&c[0]));
    Regex::new(r"\n{3,}").unwrap().replace_all(&text, "\n\n").trim().to_string()
}
fn url_host(u: &str) -> String { u.split("//").nth(1).and_then(|r| r.split('/').next()).map(|h| h.trim_start_matches("www.").to_string()).unwrap_or_else(|| u.into()) }

fn sections(text: &str) -> Vec<Section> {
    skim::sections(text).into_iter().map(|s| { let body = skim::strip(&s.body); Section { heading: s.heading.unwrap_or_default().into(), breaks: body.matches('\n').count() as i32, body: body.into() } }).collect()
}

fn greeting(name: &str) -> String {
    use chrono::Timelike;
    let h = chrono::Local::now().hour();
    let g = match h { 4..=11 => "Good morning", 12..=17 => "Good afternoon", _ => "Good evening" };
    if name.trim().is_empty() { format!("{g}.") } else { format!("{g}, {}.", name.trim()) }
}

/// The same topics as the Mac app (NewsCategory).
const TOPICS: &[(&str, &str)] = &[("world", "World"), ("politics", "Politics"), ("australia", "Australia"), ("business", "Business"), ("economy", "Economy"), ("technology", "Technology"), ("ai", "AI"),
    ("science", "Science"), ("space", "Space"), ("health", "Health"), ("climate", "Climate"), ("sport", "Sport"), ("gaming", "Gaming"), ("aviation", "Aviation"), ("entertainment", "Entertainment"),
    ("film", "Film and TV"), ("music", "Music"), ("books", "Books"), ("design", "Design"), ("food", "Food"), ("travel", "Travel")];

fn topic_rows(chosen: &[String]) -> ModelRc<TopicRow> {
    let all: Vec<Topic> = TOPICS.iter().enumerate().map(|(i, (id, name))| Topic { id: (*id).into(), name: (*name).into(), on: chosen.iter().any(|c| c == id), index: i as i32 }).collect();
    model(all.chunks(5).map(|c| TopicRow { items: model(c.to_vec()) }).collect())
}

struct State {
    chosen: Vec<String>,
    rows: Vec<Value>,
    replies: Vec<Value>,
    briefing: String,
    deck: Vec<Value>,
    turns: Vec<(bool, String, String)>,
    pending: Option<(String, String)>,
    sink: Option<Arc<rodio::Sink>>,
}

fn main() -> Result<(), slint::PlatformError> {
    let dir = data_dir();
    if let Err(e) = everyday_mobile::init(&dir) { eprintln!("storage: {e}"); }
    let ui = AppWindow::new()?;
    let secrets: Secrets = Arc::new(OsSecrets::new("everyday."));
    let state = Rc::new(std::cell::RefCell::new(State { chosen: vec![], rows: vec![], replies: vec![], briefing: String::new(), deck: vec![], turns: vec![], pending: None, sink: None }));
    let toast_timer = Rc::new(Timer::default());
    let send_timer = Rc::new(Timer::default());

    let toast = { let ui = ui.as_weak(); let t = toast_timer.clone(); move |m: String| {
        if let Some(u) = ui.upgrade() { u.set_toast(m.into()); let ui2 = ui.clone(); t.start(TimerMode::SingleShot, Duration::from_secs(4), move || { if let Some(u) = ui2.upgrade() { u.set_toast("".into()); } }); }
    } };
    let toast = Rc::new(toast);

    // Everything stored locally, shown at once; then a network refresh.
    let load_local = { let st8 = state.clone(); let s = secrets.clone(); move |ui: &AppWindow| {
        let s = &*s;
        let rows = run(s, "inbox", json!({})).ok().and_then(|v| v.as_array().cloned()).unwrap_or_default();
        let to_row = |v: &Value| MailRow { thread_id: st(v, "threadId"), from: { let f = st(v, "from"); if f.is_empty() { st(v, "fromAddress") } else { f } }, subject: st(v, "subject"),
            summary: { let s = st(v, "summary"); if s.is_empty() { st(v, "snippet") } else { s } }, time: short_time(v["date"].as_i64().unwrap_or(0)).into(),
            attention: v["attention"].as_bool().unwrap_or(false), security: v["security"].as_bool().unwrap_or(false), count: v["count"].as_i64().unwrap_or(1) as i32 };
        ui.set_needs(model(rows.iter().filter(|r| r["attention"].as_bool() == Some(true)).map(to_row).collect()));
        ui.set_rest(model(rows.iter().filter(|r| r["attention"].as_bool() != Some(true)).take(200).map(to_row).collect()));
        st8.borrow_mut().rows = rows;
        let story = |v: &Value| Story { title: st(v, "title"), source: st(v, "source"), summary: skim::strip(v["summary"].as_str().unwrap_or_default()).into(), url: st(v, "url") };
        let stories = run(s, "stories", json!({})).ok().and_then(|v| v.as_array().cloned()).unwrap_or_default();
        ui.set_stories(model(stories.iter().map(story).collect()));
        let deck = run(s, "swipeDeck", json!({})).ok().and_then(|v| v.as_array().cloned()).unwrap_or_default();
        ui.set_deck(model(deck.iter().map(story).collect()));
        st8.borrow_mut().deck = deck;
        let now = chrono::Local::now().timestamp();
        let tasks = run(s, "tasks", json!({})).ok().and_then(|v| v.as_array().cloned()).unwrap_or_default();
        ui.set_tasks(model(tasks.iter().map(|t| { let due = t["due"].as_i64(); TaskItem { id: st(t, "id"), title: st(t, "title"),
            due: due.and_then(|d| chrono::TimeZone::timestamp_opt(&chrono::Local, d, 0).single()).map(|d| d.format("%a %-d %b, %-H:%M").to_string()).unwrap_or_default().into(), overdue: due.map_or(false, |d| d < now) } }).collect()));
    } };
    let load_local = Rc::new(load_local);

    // First paint.
    {
        let s = &*secrets;
        let state_v = run(s, "state", json!({})).unwrap_or(json!({}));
        let pref = |k: &str| run(s, "getPref", json!({"key": k})).ok().and_then(|v| v.as_str().map(String::from)).unwrap_or_default();
        let name = pref("name");
        ui.set_name(name.clone().into());
        ui.set_email(state_v["email"].as_str().unwrap_or_default().into());
        ui.set_has_key(state_v["hasAiKey"].as_bool().unwrap_or(false));
        ui.set_onboarded(pref("onboarded") == "1" || std::env::var("EVERYDAY_SKIP_SETUP").is_ok());
        if let Ok(p) = std::env::var("EVERYDAY_PAGE") { ui.set_page(p.parse().unwrap_or(0)); }
        ui.set_ics(pref("icsUrl").into());
        ui.set_morning(pref("morningOn") == "1");
        ui.set_hour(pref("morningHour").parse().unwrap_or(7));
        ui.set_greeting(greeting(&name).into());
        ui.set_instructions(pref("briefingInstructions").into());
        let chosen: Vec<String> = pref("categories").split(',').filter(|c| !c.is_empty()).map(String::from).collect();
        ui.set_topics(topic_rows(&chosen)); state.borrow_mut().chosen = chosen;
        ui.set_top_interests(run(s, "topInterests", json!({})).ok().and_then(|v| v.as_array().map(|a| a.iter().filter_map(|x| x.as_str()).collect::<Vec<_>>().join(", "))).unwrap_or_default().into());
        ui.set_date_text(chrono::Local::now().format("%A %-d %B").to_string().into());
        if let Ok(b) = run(s, "lastBriefing", json!({})) { if let Some(t) = b["text"].as_str() { state.borrow_mut().briefing = t.into(); ui.set_briefing(model(sections(t))); } }
        load_local(&ui);
        ui.set_ready(true);
    }

    let refresh = { let ui_w = ui.as_weak(); let s = secrets.clone(); let ll = load_local.clone(); let toast = toast.clone(); move || {
        let Some(ui) = ui_w.upgrade() else { return };
        if ui.get_syncing() { return; }
        ui.set_syncing(true);
        let has_mail = !ui.get_email().is_empty();
        let ll = ll.clone(); let toast = toast.clone();
        bg(&ui, &s, move |s| {
            let mail = if has_mail { run(s, "syncMail", json!({})).err() } else { None };
            let _ = run(s, "newsRefresh", json!({}));
            let events = run(s, "upcoming", json!({})).ok().and_then(|v| v.as_array().cloned()).unwrap_or_default();
            (mail, events)
        }, move |ui, (mail, events)| {
            ui.set_syncing(false);
            if let Some(e) = mail { toast(e); }
            ui.set_events(model(events.iter().take(5).map(|e| EventRow { title: st(e, "title"), when: st(e, "when") }).collect()));
            ll(&ui);
        });
    } };
    let refresh = Rc::new(refresh);
    ui.on_refresh({ let r = refresh.clone(); move || r() });
    refresh();
    // Mail and news every ten minutes; the morning briefing once a day from the chosen hour.
    let tick = Timer::default();
    tick.start(TimerMode::Repeated, Duration::from_secs(600), { let r = refresh.clone(); let ui_w = ui.as_weak(); let s = secrets.clone(); move || {
        r();
        if let Some(ui) = ui_w.upgrade() { if run(&*s, "morningDue", json!({})).ok() == Some(json!(true)) { ui.invoke_write_briefing(); } }
    } });

    ui.on_write_briefing({ let ui_w = ui.as_weak(); let s = secrets.clone(); let st8 = state.clone(); let toast = toast.clone(); move || {
        let Some(ui) = ui_w.upgrade() else { return };
        if ui.get_writing() { return; }
        ui.set_writing(true);
        let st8 = st8.clone(); let toast = toast.clone();
        bg(&ui, &s, |s| {
            let text = run(s, "briefing", json!({}))?;
            let t = text.as_str().unwrap_or_default().to_string();
            let replies = run(s, "quickReplies", json!({"briefing": t})).ok().and_then(|v| v.as_array().cloned()).unwrap_or_default();
            Ok::<_, String>((t, replies))
        }, move |ui, r| {
            ui.set_writing(false);
            match r {
                Ok((t, replies)) => {
                    ui.set_briefing(model(sections(&t)));
                    ui.set_replies(model(replies.iter().enumerate().map(|(i, r)| ReplyChip { label: st(r, "label"), handled: r["kind"] == "handled", index: i as i32 }).collect()));
                    let mut s = st8.borrow_mut(); s.briefing = t; s.replies = replies;
                }
                Err(e) => toast(e),
            }
        });
    } });

    ui.on_reply({ let ui_w = ui.as_weak(); let s = secrets.clone(); let st8 = state.clone(); let ll = load_local.clone(); move |i| {
        let Some(ui) = ui_w.upgrade() else { return };
        let r = st8.borrow().replies.get(i as usize).cloned(); let Some(r) = r else { return };
        let ids: Vec<String> = r["threadIds"].as_array().map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default();
        if r["kind"] == "handled" {
            let _ = run(&*s, "markHandled", json!({"threadIds": ids}));
            st8.borrow_mut().replies.remove(i as usize);
            let left = st8.borrow().replies.clone();
            ui.set_replies(model(left.iter().enumerate().map(|(i, r)| ReplyChip { label: st(r, "label"), handled: r["kind"] == "handled", index: i as i32 }).collect()));
            ll(&ui);
        } else if let Some(t) = ids.first() {
            ui.set_draft(st(&r, "text")); ui.set_page(1); ui.invoke_open_thread(t.into());
        }
    } });

    ui.on_open_thread({ let ui_w = ui.as_weak(); let s = secrets.clone(); let st8 = state.clone(); move |tid| {
        let Some(ui) = ui_w.upgrade() else { return };
        let row = st8.borrow().rows.iter().find(|r| r["threadId"].as_str() == Some(tid.as_str())).cloned().unwrap_or(json!({}));
        let msgs = run(&*s, "thread", json!({"threadId": tid.as_str()})).ok().and_then(|v| v.as_array().cloned()).unwrap_or_default();
        ui.set_selected(tid);
        ui.set_subject({ let s = st(&row, "subject"); if s.is_empty() { "(no subject)".into() } else { s } });
        ui.set_summary(st(&row, "summary"));
        ui.set_security(row["security"].as_bool().unwrap_or(false));
        ui.set_messages(model(msgs.iter().map(|m| Msg { from: { let f = st(m, "from"); if f.is_empty() { st(m, "fromAddress") } else { f } },
            time: chrono::TimeZone::timestamp_opt(&chrono::Local, m["date"].as_i64().unwrap_or(0), 0).single().map(|d| d.format("%a %-d %b, %-H:%M").to_string()).unwrap_or_default().into(),
            body: { let b = readable(m["body"].as_str().unwrap_or_default()); b.clone().into() }, breaks: readable(m["body"].as_str().unwrap_or_default()).matches('\n').count() as i32,
            attachments: m["attachments"].as_array().map(|a| a.iter().filter_map(|x| x.as_str()).collect::<Vec<_>>().join(", ")).unwrap_or_default().into() }).collect()));
    } });

    // Thread actions: the row disappears at once; a failure brings it back with the reason.
    let act = { let ui_w = ui.as_weak(); let s = secrets.clone(); let ll = load_local.clone(); let toast = toast.clone(); move |cmd: &'static str, extra: Value, done_msg: String| {
        let Some(ui) = ui_w.upgrade() else { return };
        let tid = ui.get_selected().to_string(); if tid.is_empty() { return; }
        ui.set_selected("".into());
        let mut args = extra; args["threadId"] = json!(tid); if cmd == "markHandled" { args = json!({"threadIds": [tid]}); }
        let ll = ll.clone(); let toast = toast.clone();
        bg(&ui, &s, move |s| run(s, cmd, args), move |ui, r| { match r { Ok(_) => toast(done_msg), Err(e) => toast(e) } ll(&ui); });
    } };
    let act = Rc::new(act);
    ui.on_archive({ let a = act.clone(); move || a("archive", json!({}), "Archived".into()) });
    ui.on_trash({ let a = act.clone(); move || a("trash", json!({}), "Moved to Trash".into()) });
    ui.on_snooze({ let a = act.clone(); move |h| a("snooze", json!({"hours": h}), "Snoozed".into()) });
    ui.on_handled({ let a = act.clone(); move || a("markHandled", json!({}), "Marked as handled".into()) });

    // Send waits ten seconds so it can be undone; only then does the core send it.
    ui.on_send({ let ui_w = ui.as_weak(); let s = secrets.clone(); let st8 = state.clone(); let t = send_timer.clone(); let toast = toast.clone(); move || {
        let Some(ui) = ui_w.upgrade() else { return };
        let body = ui.get_draft().trim().to_string(); if body.is_empty() { return; }
        st8.borrow_mut().pending = Some((ui.get_selected().to_string(), body)); ui.set_draft("".into()); ui.set_countdown(10);
        let ui_w2 = ui_w.clone(); let s = s.clone(); let st8 = st8.clone(); let t2 = t.clone(); let toast = toast.clone();
        t.start(TimerMode::Repeated, Duration::from_secs(1), move || {
            let Some(ui) = ui_w2.upgrade() else { return };
            let c = ui.get_countdown() - 1; ui.set_countdown(c.max(0));
            if c > 0 { return; }
            t2.stop();
            let Some((tid, body)) = st8.borrow_mut().pending.take() else { return };
            let toast = toast.clone();
            bg(&ui, &s, move |s| run(s, "sendReply", json!({"threadId": tid, "body": body.clone()})).map_err(|e| (e, body)), move |ui, r| match r {
                Ok(_) => toast("Sent".into()),
                Err((e, body)) => { ui.set_draft(body.into()); toast(format!("{e} Your reply is back in the box.")); }
            });
        });
    } });
    ui.on_undo({ let ui_w = ui.as_weak(); let st8 = state.clone(); let t = send_timer.clone(); move || {
        t.stop(); let Some(ui) = ui_w.upgrade() else { return };
        if let Some((_, body)) = st8.borrow_mut().pending.take() { ui.set_draft(body.into()); }
        ui.set_countdown(0);
    } });

    ui.on_open_url(|u| { let _ = open::that(u.as_str()); });
    ui.on_react({ let ui_w = ui.as_weak(); let s = secrets.clone(); let st8 = state.clone(); move |r| {
        let Some(ui) = ui_w.upgrade() else { return };
        let first = { let mut st = st8.borrow_mut(); if st.deck.is_empty() { return; } st.deck.remove(0) };
        let _ = run(&*s, "react", json!({"url": first["url"], "title": first["title"], "source": first["source"], "reaction": r as f64}));
        if let Some(t) = run(&*s, "topInterests", json!({})).ok().and_then(|v| v.as_array().map(|a| a.iter().filter_map(|x| x.as_str()).collect::<Vec<_>>().join(", "))) { ui.set_top_interests(t.into()); }
        let deck = st8.borrow().deck.clone();
        ui.set_deck(model(deck.iter().map(|v| Story { title: st(v, "title"), source: st(v, "source"), summary: skim::strip(v["summary"].as_str().unwrap_or_default()).into(), url: st(v, "url") }).collect()));
    } });

    ui.on_add_task({ let ui_w = ui.as_weak(); let s = secrets.clone(); let ll = load_local.clone(); move || {
        let Some(ui) = ui_w.upgrade() else { return };
        let input = ui.get_task_input().trim().to_string(); if input.is_empty() { return; }
        let _ = run(&*s, "addTask", json!({"input": input})); ui.set_task_input("".into()); ll(&ui);
    } });
    ui.on_toggle_task({ let ui_w = ui.as_weak(); let s = secrets.clone(); let ll = load_local.clone(); move |id| {
        let Some(ui) = ui_w.upgrade() else { return };
        let _ = run(&*s, "toggleTask", json!({"id": id.as_str()}));
        // Let the tick show for a moment before the row leaves.
        let ui_w = ui.as_weak(); let ll = ll.clone();
        Timer::single_shot(Duration::from_millis(350), move || { if let Some(ui) = ui_w.upgrade() { ll(&ui); } });
    } });
    ui.on_delete_task({ let ui_w = ui.as_weak(); let s = secrets.clone(); let ll = load_local.clone(); move |id| {
        let Some(ui) = ui_w.upgrade() else { return };
        let _ = run(&*s, "deleteTask", json!({"id": id.as_str()})); ll(&ui);
    } });

    ui.on_ask({ let ui_w = ui.as_weak(); let s = secrets.clone(); let st8 = state.clone(); move |q| {
        let Some(ui) = ui_w.upgrade() else { return };
        let q = q.trim().to_string(); if q.is_empty() || ui.get_thinking() { return; }
        let history: Vec<Value> = st8.borrow().turns.iter().map(|(m, t, _)| json!({"role": if *m { "user" } else { "assistant" }, "text": t})).collect();
        st8.borrow_mut().turns.push((true, q.clone(), String::new()));
        let show = |ui: &AppWindow, st8: &Rc<std::cell::RefCell<State>>| ui.set_turns(model(st8.borrow().turns.iter().map(|(m, t, s)| Turn { mine: *m, text: t.into(), sources: s.into() }).collect()));
        show(&ui, &st8); ui.set_ask_input("".into()); ui.set_thinking(true);
        let st8 = st8.clone();
        bg(&ui, &s, move |s| run(s, "ask", json!({"question": q, "history": history})), move |ui, r| {
            ui.set_thinking(false);
            let (text, src) = match r { Ok(v) => (skim::strip(v["text"].as_str().unwrap_or_default()), v["sources"].as_array().map(|a| a.iter().filter_map(|x| x["title"].as_str()).collect::<Vec<_>>().join(", ")).unwrap_or_default()), Err(e) => (e, String::new()) };
            st8.borrow_mut().turns.push((false, text, src));
            show(&ui, &st8);
        });
    } });

    ui.on_listen({ let ui_w = ui.as_weak(); let s = secrets.clone(); let st8 = state.clone(); let toast = toast.clone(); move || {
        let Some(ui) = ui_w.upgrade() else { return };
        if let Some(sink) = st8.borrow_mut().sink.take() { sink.stop(); ui.set_speaking(false); return; }
        let text = skim::plain(&st8.borrow().briefing); ui.set_speaking(true);
        let st8 = st8.clone(); let toast = toast.clone(); let ui_w2 = ui.as_weak();
        bg(&ui, &s, move |s| run(s, "speak", json!({"text": text})), move |ui, r| match r {
            Ok(path) => {
                let path = path.as_str().unwrap_or_default().to_string();
                let (tx, rx) = std::sync::mpsc::channel::<Arc<rodio::Sink>>();
                std::thread::spawn(move || {
                    let Ok((_stream, handle)) = rodio::OutputStream::try_default() else { return };
                    let Ok(sink) = rodio::Sink::try_new(&handle) else { return };
                    if let Ok(f) = std::fs::File::open(&path) { if let Ok(src) = rodio::Decoder::new(std::io::BufReader::new(f)) { sink.append(src); } }
                    let sink = Arc::new(sink); let _ = tx.send(sink.clone());
                    sink.sleep_until_end();
                    let _ = ui_w2.upgrade_in_event_loop(|ui| ui.set_speaking(false));
                });
                if let Ok(sink) = rx.recv_timeout(Duration::from_secs(3)) { st8.borrow_mut().sink = Some(sink); } else { ui.set_speaking(false); }
            }
            Err(e) => { ui.set_speaking(false); toast(e); }
        });
    } });

    // Settings and setup.
    ui.on_save_name({ let ui_w = ui.as_weak(); let s = secrets.clone(); move || { let Some(ui) = ui_w.upgrade() else { return }; let n = ui.get_name().trim().to_string(); let _ = run(&*s, "setPref", json!({"key": "name", "value": n})); ui.set_greeting(greeting(&n).into()); } });
    ui.on_save_ics({ let ui_w = ui.as_weak(); let s = secrets.clone(); move || { let Some(ui) = ui_w.upgrade() else { return }; let _ = run(&*s, "setPref", json!({"key": "icsUrl", "value": ui.get_ics().trim()})); } });
    ui.on_save_morning({ let ui_w = ui.as_weak(); let s = secrets.clone(); move || { let Some(ui) = ui_w.upgrade() else { return };
        let _ = run(&*s, "setPref", json!({"key": "morningOn", "value": if ui.get_morning() { "1" } else { "0" }}));
        let _ = run(&*s, "setPref", json!({"key": "morningHour", "value": ui.get_hour().to_string()})); } });
    ui.on_connect({ let ui_w = ui.as_weak(); let s = secrets.clone(); let r = refresh.clone(); move || {
        let Some(ui) = ui_w.upgrade() else { return };
        let presets = [("imap.gmail.com", "smtp.gmail.com", 465), ("imap.mail.me.com", "smtp.mail.me.com", 587), ("outlook.office365.com", "smtp.office365.com", 587), ("imap.fastmail.com", "smtp.fastmail.com", 465)];
        let (ih, sh, sp) = presets[ui.get_provider().clamp(0, 3) as usize];
        let email = ui.get_mail_email().trim().to_string(); let pw = ui.get_mail_password().to_string();
        if !email.contains('@') || pw.len() < 8 { ui.set_error("Enter your email address and the app password.".into()); return; }
        ui.set_busy(true); ui.set_error("".into());
        let r = r.clone();
        bg(&ui, &s, move |s| run(s, "connectMail", json!({"email": email.clone(), "password": pw, "imapHost": ih, "imapPort": 993, "smtpHost": sh, "smtpPort": sp})).map(|_| email), move |ui, res| {
            ui.set_busy(false);
            match res { Ok(email) => { ui.set_email(email.into()); ui.set_mail_password("".into()); if !ui.get_onboarded() { ui.set_step(5); } r(); } Err(e) => ui.set_error(e.into()) }
        });
    } });
    ui.on_disconnect({ let ui_w = ui.as_weak(); let s = secrets.clone(); let ll = load_local.clone(); move || {
        let Some(ui) = ui_w.upgrade() else { return };
        s.delete(&everyday_core::secrets::password_key(&ui.get_email()));
        let _ = run(&*s, "disconnectMail", json!({})); ui.set_email("".into()); ui.set_selected("".into()); ll(&ui);
    } });
    ui.on_save_key({ let ui_w = ui.as_weak(); let s = secrets.clone(); move || {
        let Some(ui) = ui_w.upgrade() else { return };
        let k = ui.get_key_input().trim().to_string(); if k.is_empty() { return; }
        ui.set_key_note("Checking the key…".into());
        bg(&ui, &s, move |s| { run(s, "saveAiKey", json!({"key": k}))?; run(s, "aiTest", json!({})) }, |ui, r| match r {
            Ok(_) => { ui.set_has_key(true); ui.set_key_input("".into()); ui.set_key_note("Key saved and working.".into()); if !ui.get_onboarded() { ui.invoke_finish(); } }
            Err(e) => ui.set_key_note(e.into()),
        });
    } });
    ui.on_toggle_topic({ let ui_w = ui.as_weak(); let st8 = state.clone(); let s = secrets.clone(); move |i| {
        let Some(ui) = ui_w.upgrade() else { return };
        let id = TOPICS[i as usize].0.to_string();
        { let mut st = st8.borrow_mut(); if let Some(p) = st.chosen.iter().position(|c| *c == id) { st.chosen.remove(p); } else { st.chosen.push(id.clone()); } }
        let chosen = st8.borrow().chosen.clone();
        ui.set_topics(topic_rows(&chosen));
        let _ = run(&*s, "setPref", json!({"key": "categories", "value": chosen.join(",")}));
        if ui.get_onboarded() && chosen.contains(&id) { let _ = run(&*s, "seedInterests", json!({"categories": [id]})); }
    } });
    ui.on_save_topics({ let st8 = state.clone(); let s = secrets.clone(); let ui_w = ui.as_weak(); let ll = load_local.clone(); move || {
        let chosen = st8.borrow().chosen.clone();
        let _ = run(&*s, "seedInterests", json!({"categories": chosen}));
        if let Some(ui) = ui_w.upgrade() { ll(&ui); }
    } });
    let interests_text = { let s = secrets.clone(); move || run(&*s, "topInterests", json!({})).ok().and_then(|v| v.as_array().map(|a| a.iter().filter_map(|x| x.as_str()).collect::<Vec<_>>().join(", "))).unwrap_or_default() };
    let interests_text = Rc::new(interests_text);
    ui.on_train({ let ui_w = ui.as_weak(); let ll = load_local.clone(); move || { let Some(ui) = ui_w.upgrade() else { return }; ll(&ui); ui.set_news_mode(1); ui.set_page(2); } });
    ui.on_reset_interests({ let ui_w = ui.as_weak(); let s = secrets.clone(); let ll = load_local.clone(); let it = interests_text.clone(); let st8 = state.clone(); let toast = toast.clone(); move || {
        let Some(ui) = ui_w.upgrade() else { return };
        let _ = run(&*s, "resetInterests", json!({}));
        let chosen = st8.borrow().chosen.clone(); let _ = run(&*s, "seedInterests", json!({"categories": chosen}));
        ui.set_top_interests(it().into()); ll(&ui); toast("Started over from your topics".into());
    } });
    ui.on_save_instructions({ let ui_w = ui.as_weak(); let s = secrets.clone(); move || { let Some(ui) = ui_w.upgrade() else { return }; let _ = run(&*s, "setPref", json!({"key": "briefingInstructions", "value": ui.get_instructions().trim()})); } });
    ui.on_finish({ let ui_w = ui.as_weak(); let s = secrets.clone(); move || { let Some(ui) = ui_w.upgrade() else { return }; let _ = run(&*s, "setPref", json!({"key": "onboarded", "value": "1"})); ui.set_onboarded(true); ui.set_page(0); } });

    ui.run()
}

/// %APPDATA%\everyday on Windows; the usual per-user data folder elsewhere.
fn data_dir() -> String {
    if let Ok(d) = std::env::var("EVERYDAY_DATA") { return d; }
    #[cfg(windows)] { if let Ok(a) = std::env::var("APPDATA") { return format!("{a}\\everyday"); } }
    #[cfg(target_os = "macos")] { if let Ok(h) = std::env::var("HOME") { return format!("{h}/Library/Application Support/everyday-windows-preview"); } }
    format!("{}/.local/share/everyday", std::env::var("HOME").unwrap_or_else(|_| ".".into()))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn readable_mail_drops_tracking_links() {
        assert_eq!(readable("Set up a passkey <https://accounts.google.com/x?y=1>\n<https://track.example/pixel>\nSee https://www.example.com/a/b"), "Set up a passkey\nSee example.com");
    }
    #[test] fn greeting_uses_the_name() { assert!(greeting("Xavi").ends_with(", Xavi.")); assert!(greeting("").ends_with('.')); }
}
