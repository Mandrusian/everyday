//! Local mail rules, ported from `MailService`: one row per conversation, handled threads, snooze, VIP senders, "needs attention".
//! Nothing here touches the mail account: these are the app's own local decisions.
use crate::bundler::{domain_key, is_automated, Category};
use std::collections::{HashMap, HashSet};

#[derive(Debug, Clone)]
pub struct Email { pub id: String, pub thread_id: String, pub from_name: String, pub from_address: String, pub subject: String, pub date: i64 }

#[derive(Debug, Clone, PartialEq)]
pub struct Triage { pub message_id: String, pub category: Category, pub priority: u8, pub summary: String, pub deadline: Option<i64>, pub needs_reply: bool }

#[derive(Debug, Clone)]
pub struct Row { pub message: Email, pub triage: Option<Triage>, pub thread_count: usize }

#[derive(Debug, Default)]
pub struct Local { pub handled: HashSet<String>, pub snoozed: HashMap<String, i64>, pub vips: HashSet<String>, pub rules: Vec<Rule> }

/// "Treat mail like this as handled": matches on sender and subject text.
#[derive(Debug, Clone)]
pub struct Rule { pub sender_contains: String, pub subject_contains: String }
impl Rule {
    pub fn matches(&self, m: &Email) -> bool {
        let sender = format!("{} {}", m.from_address, m.from_name).to_lowercase();
        if !self.sender_contains.is_empty() && !sender.contains(&self.sender_contains.to_lowercase()) { return false; }
        if !self.subject_contains.is_empty() && !m.subject.to_lowercase().contains(&self.subject_contains.to_lowercase()) { return false; }
        !self.sender_contains.is_empty() || !self.subject_contains.is_empty()
    }
}

fn quieted(t: &Triage) -> Triage { Triage { category: Category::Fyi, priority: t.priority.min(5), deadline: None, needs_reply: false, ..t.clone() } }

/// Conversations that need the user right now.
pub fn is_attention(r: &Row) -> bool {
    let Some(t) = &r.triage else { return false };
    (t.needs_reply || t.deadline.is_some() || t.priority >= 75) && !matches!(t.category, Category::Newsletter | Category::Promo | Category::Fyi)
}

/// One row per thread (latest message), sorted by priority then recency, with the local rules applied.
pub fn rows(emails: &[Email], triage: &HashMap<String, Triage>, local: &Local, now: i64) -> Vec<Row> {
    let mut by_thread: HashMap<&str, Vec<&Email>> = HashMap::new();
    for e in emails { by_thread.entry(&e.thread_id).or_default().push(e); }
    let mut out: Vec<Row> = by_thread.into_iter().filter_map(|(tid, msgs)| {
        let latest = msgs.iter().max_by_key(|m| m.date)?;
        let sn = local.snoozed.get(tid).copied();
        if matches!(sn, Some(until) if until > now) { return None; }                         // put away until later
        let mut t = triage.get(&latest.id).cloned().or_else(|| msgs.iter().filter_map(|m| triage.get(&m.id)).max_by_key(|t| t.priority).cloned());
        if local.vips.contains(&latest.from_address.to_lowercase()) {                          // VIP senders always rise
            let b = t.clone().unwrap_or(Triage { message_id: latest.id.clone(), category: Category::Important, priority: 95, summary: latest.subject.clone(), deadline: None, needs_reply: false });
            let cat = if matches!(b.category, Category::Newsletter | Category::Promo | Category::Fyi | Category::SpamSuspect) { Category::Important } else { b.category };
            t = Some(Triage { category: cat, priority: b.priority.max(95), ..b });
        }
        if matches!(sn, Some(until) if until <= now) {                                         // snooze over: it needs you
            let b = t.clone().unwrap_or(Triage { message_id: latest.id.clone(), category: Category::NeedsReply, priority: 90, summary: latest.subject.clone(), deadline: None, needs_reply: true });
            t = Some(Triage { category: Category::NeedsReply, priority: b.priority.max(90), needs_reply: true, ..b });
        }
        if let Some(x) = &t { if local.handled.contains(tid) || local.rules.iter().any(|r| r.matches(latest)) { t = Some(quieted(x)); } }
        Some(Row { message: (*latest).clone(), triage: t, thread_count: msgs.len() })
    }).collect();
    out.sort_by(|a, b| {
        let (pa, pb) = (a.triage.as_ref().map_or(-1, |t| t.priority as i32), b.triage.as_ref().map_or(-1, |t| t.priority as i32));
        pb.cmp(&pa).then(b.message.date.cmp(&a.message.date))
    });
    out
}

/// Sender names the briefing must not mention: handled senders that no still-open item shares.
pub fn banned_names(rows_: &[Row], local: &Local) -> Vec<String> {
    let open: HashSet<String> = rows_.iter().filter(|r| is_attention(r)).map(|r| r.message.from_name.to_lowercase()).collect();
    let mut seen = HashSet::new(); let mut out = vec![];
    for r in rows_ {
        let handled = local.handled.contains(&r.message.thread_id) || local.rules.iter().any(|x| x.matches(&r.message));
        let n = r.message.from_name.trim();
        if handled && n.len() >= 3 && !n.contains('@') && !open.contains(&n.to_lowercase()) && seen.insert(n.to_lowercase()) { out.push(n.to_string()); }
    }
    out
}

pub fn same_group(a: &Email, b: &Email) -> bool { domain_key(&a.from_address) == domain_key(&b.from_address) && is_automated(&a.from_address, None) && is_automated(&b.from_address, None) }

#[cfg(test)]
mod tests {
    use super::*;
    fn e(id: &str, thread: &str, name: &str, addr: &str, subj: &str) -> Email { Email { id: id.into(), thread_id: thread.into(), from_name: name.into(), from_address: addr.into(), subject: subj.into(), date: 100 } }
    fn tri(id: &str, cat: Category, pr: u8) -> (String, Triage) { (id.into(), Triage { message_id: id.into(), category: cat, priority: pr, summary: "s".into(), deadline: None, needs_reply: false }) }
    fn data() -> (Vec<Email>, HashMap<String, Triage>) {
        let emails = vec![e("1", "t1", "Dana", "dana@acme.com", "Roadmap"), e("2", "t2", "Brew", "hi@brew.com", "Weekday briefing")];
        (emails, [tri("1", Category::Newsletter, 20), tri("2", Category::Newsletter, 20)].into_iter().collect())
    }
    #[test] fn snoozed_leave_the_inbox_and_come_back_needing_attention() {
        let (emails, t) = data(); let mut l = Local::default();
        l.snoozed.insert("t1".into(), 1000);
        assert!(!rows(&emails, &t, &l, 500).iter().any(|r| r.message.thread_id == "t1"));
        let back = rows(&emails, &t, &l, 2000); let r = back.iter().find(|r| r.message.thread_id == "t1").unwrap();
        assert!(is_attention(r)); assert_eq!(back[0].message.thread_id, "t1");
    }
    #[test] fn vip_newsletter_rises_to_important_95() {
        let (emails, t) = data(); let mut l = Local::default(); l.vips.insert("hi@brew.com".into());
        let rs = rows(&emails, &t, &l, 0); let r = rs.iter().find(|r| r.message.thread_id == "t2").unwrap();
        let tr = r.triage.as_ref().unwrap(); assert_eq!((tr.priority, tr.category), (95, Category::Important));
        l.vips.clear(); assert_eq!(rows(&emails, &t, &l, 0).iter().find(|r| r.message.thread_id == "t2").unwrap().triage.as_ref().unwrap().priority, 20);
    }
    #[test] fn handled_threads_stop_being_attention_and_their_sender_is_banned_from_the_briefing() {
        let emails = vec![e("g1", "gt1", "Google", "no-reply@accounts.google.com", "App password created"), e("d1", "dt1", "Dana Whitfield", "dana@acme.com.au", "Roadmap sync")];
        let t: HashMap<String, Triage> = [tri("g1", Category::Important, 90), tri("d1", Category::Important, 90)].into_iter().collect();
        let mut l = Local::default();
        assert_eq!(rows(&emails, &t, &l, 0).iter().filter(|r| is_attention(r)).count(), 2);
        l.handled.insert("gt1".into());
        let rs = rows(&emails, &t, &l, 0);
        assert_eq!(rs.iter().filter(|r| is_attention(r)).map(|r| r.message.from_name.as_str()).collect::<Vec<_>>(), ["Dana Whitfield"]);
        assert_eq!(banned_names(&rs, &l), ["Google"]);
    }
    #[test] fn rules_match_sender_and_subject() {
        let r = Rule { sender_contains: "google".into(), subject_contains: "app password".into() };
        assert!(r.matches(&e("1", "t", "Google", "no-reply@accounts.google.com", "App password created")));
        assert!(!r.matches(&e("2", "t", "Google", "no-reply@accounts.google.com", "Security alert")));
        assert!(!Rule { sender_contains: String::new(), subject_contains: String::new() }.matches(&e("3", "t", "x", "x@y.z", "s")));
    }
}
