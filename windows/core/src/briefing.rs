//! The daily briefing: what goes to the model, the prompt, and the guarantee that handled senders never appear.
use crate::ai::{self, AiError, GUARDRAIL};
use crate::mailrules::{self, Local, Row};
use crate::skim;

pub struct Inputs<'a> { pub rows: &'a [Row], pub local: &'a Local, pub tasks: &'a [String], pub weather: Option<String>, pub calendar: Option<String>, pub news: &'a [String], pub standing_instructions: &'a str }

/// The data block sent to the model. Handled mail is listed separately so the model is told not to mention it.
pub fn context(i: &Inputs) -> String {
    let mut out: Vec<String> = vec![];
    let attention: Vec<&Row> = i.rows.iter().filter(|r| r.triage.as_ref().map_or(false, |t| !matches!(t.category, crate::bundler::Category::Newsletter | crate::bundler::Category::Promo | crate::bundler::Category::SpamSuspect) && t.priority >= 40)).take(12).collect();
    if !attention.is_empty() {
        out.push("EMAIL NEEDING ATTENTION (priority-ordered):".into());
        for r in attention { let t = r.triage.as_ref().unwrap(); out.push(format!("- [priority {}] {}: {} — {}{}", t.priority, r.message.from_name, r.message.subject, t.summary, if t.needs_reply { " (reply owed)" } else { "" })); }
    }
    let banned = mailrules::banned_names(i.rows, i.local);
    if !banned.is_empty() {
        out.push("\nALREADY HANDLED BY THE READER (they said these were them or do not matter; never mention these senders or anything like them):".into());
        for b in &banned { out.push(format!("- {b}")); }
    }
    if !i.tasks.is_empty() { out.push("\nOPEN TASKS:".into()); out.extend(i.tasks.iter().take(12).map(|t| format!("- {t}"))); }
    if let Some(c) = i.calendar.as_ref().filter(|c| !c.is_empty()) { out.push(format!("\nCALENDAR TODAY: {c}")); }
    if let Some(w) = &i.weather { out.push(format!("\nWEATHER: {w}")); }
    if !i.news.is_empty() { out.push("\nTOP NEWS:".into()); out.extend(i.news.iter().map(|n| format!("- {n}"))); }
    out.join("\n")
}

pub fn system(name: &str, today: &str, standing: &str) -> String {
    let extra = if standing.trim().is_empty() { String::new() } else { format!("\nThe reader's standing instructions for their briefing. They override your defaults, so follow them exactly: {}\n", standing.trim().chars().take(800).collect::<String>()) };
    format!("You write {name}'s daily briefing, a short personal note in warm, plain prose. Anything listed under ALREADY HANDLED BY THE READER must never be mentioned, not even in passing. Now is {today}. Cover, in this order and only if present: what needs attention (deadlines, replies owed), the calendar, the weather in one clause, then the two or three most important news stories with why they matter. 90 to 150 words, one or two paragraphs, no headings, no bullet points, no greeting. Use only facts from the data; never invent. {GUARDRAIL}{extra}")
}

/// Writes the briefing. If the draft still names a handled sender it is rewritten once, and any sentence that still does is removed.
pub fn generate(call: &dyn Fn(&ai::Request) -> Result<String, AiError>, i: &Inputs, name: &str, today: &str) -> Result<String, AiError> {
    let data = context(i);
    if data.trim().is_empty() { return Err(AiError::BadResponse("There is nothing to brief yet. Connect mail or refresh the news first.".into())); }
    let banned = mailrules::banned_names(i.rows, i.local);
    let mut text = String::new();
    for attempt in 0..2 {
        let hint = if attempt == 0 { String::new() } else { format!("\n\nYour previous draft mentioned {}, which the reader has already handled. Write it again without any mention of them.", banned.join(", ")) };
        let req = ai::Request { system: system(name, today, i.standing_instructions), messages: vec![(ai::Role::User, format!("<data>\n{data}{hint}\n</data>"))], max_tokens: 700, temperature: 0.4, json: false };
        text = call(&req)?;
        let plain = skim::strip(&text).to_lowercase();
        if !banned.iter().any(|b| plain.contains(&b.to_lowercase())) { break; }
    }
    let names: Vec<&str> = banned.iter().map(String::as_str).collect();
    Ok(skim::removing_sentences_mentioning(&names, text.trim()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bundler::Category;
    use crate::mailrules::{Email, Triage};
    use std::cell::RefCell;
    use std::collections::HashMap;
    fn rows_and_local() -> (Vec<Row>, Local) {
        let e = |id: &str, t: &str, n: &str, a: &str, s: &str| Email { id: id.into(), thread_id: t.into(), from_name: n.into(), from_address: a.into(), subject: s.into(), date: 1 };
        let emails = vec![e("g1", "gt1", "Google", "no-reply@accounts.google.com", "App password created"), e("d1", "dt1", "Dana Whitfield", "dana@acme.com.au", "Roadmap sync")];
        let tri: HashMap<String, Triage> = [("g1", Category::Important, 90u8, false), ("d1", Category::NeedsReply, 90, true)].iter().map(|(i, c, p, n)| (i.to_string(), Triage { message_id: i.to_string(), category: *c, priority: *p, summary: "s".into(), deadline: None, needs_reply: *n })).collect();
        let mut local = Local::default(); local.handled.insert("gt1".into());
        (crate::mailrules::rows(&emails, &tri, &local, 0), local)
    }
    #[test] fn context_lists_dana_as_attention_and_google_as_handled() {
        let (rows, local) = rows_and_local();
        let c = context(&Inputs { rows: &rows, local: &local, tasks: &[], weather: None, calendar: None, news: &[], standing_instructions: "" });
        let (attn, handled) = c.split_once("ALREADY HANDLED").unwrap();
        assert!(attn.contains("Dana Whitfield") && !attn.contains("Google")); assert!(handled.contains("Google"));
    }
    #[test] fn a_draft_that_names_a_handled_sender_is_rewritten_then_scrubbed() {
        let (rows, local) = rows_and_local(); let calls = RefCell::new(0);
        let call = |r: &ai::Request| -> Result<String, AiError> { *calls.borrow_mut() += 1;
            if *calls.borrow() == 2 { assert!(r.messages[0].1.contains("previous draft mentioned Google")); }
            Ok("Dana needs a reply about Thursday. Google also sent three notices today. It is 30°C.".into()) };   // stubborn model: ignores the hint
        let out = generate(&call, &Inputs { rows: &rows, local: &local, tasks: &[], weather: None, calendar: None, news: &[], standing_instructions: "" }, "Alex", "today").unwrap();
        assert_eq!(*calls.borrow(), 2); assert_eq!(out, "Dana needs a reply about Thursday. It is 30°C.");
    }
    #[test] fn a_clean_draft_is_used_as_is_with_one_call() {
        let (rows, local) = rows_and_local(); let calls = RefCell::new(0);
        let call = |_: &ai::Request| -> Result<String, AiError> { *calls.borrow_mut() += 1; Ok("Dana needs a reply.".into()) };
        assert_eq!(generate(&call, &Inputs { rows: &rows, local: &local, tasks: &[], weather: None, calendar: None, news: &[], standing_instructions: "" }, "A", "t").unwrap(), "Dana needs a reply."); assert_eq!(*calls.borrow(), 1);
    }
    #[test] fn nothing_to_brief_is_an_error_and_standing_instructions_reach_the_prompt() {
        let l = Local::default(); assert!(generate(&|_| Ok("x".into()), &Inputs { rows: &[], local: &l, tasks: &[], weather: None, calendar: None, news: &[], standing_instructions: "" }, "A", "t").is_err());
        assert!(system("A", "t", "Skip Hong Kong news").contains("Skip Hong Kong news")); assert!(system("A", "t", "").contains("never mention") || system("A", "t", "").contains("must never be mentioned"));
    }
}
