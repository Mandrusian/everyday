//! Tasks on the local store: quick add, completion with repeats, suggestions from mail wording when there is no AI key.
use crate::quickadd::{self, Priority};
use crate::repeat::Repeat;
use crate::store::Store;
use chrono::{DateTime, TimeZone};
use once_cell::sync::Lazy;
use regex::Regex;
use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
pub struct Task {
    pub id: String, pub title: String, #[serde(default)] pub notes: String, pub due: Option<i64>, pub priority: String,
    #[serde(default)] pub thread_id: Option<String>, #[serde(default)] pub completed_at: Option<i64>, pub created_at: i64, #[serde(default)] pub repeats: Option<String>,
}
impl Task { pub fn is_done(&self) -> bool { self.completed_at.is_some() } }

fn repeat_of(s: &str) -> Option<Repeat> { match s { "daily" => Some(Repeat::Daily), "weekdays" => Some(Repeat::Weekdays), "weekly" => Some(Repeat::Weekly), "monthly" => Some(Repeat::Monthly), "yearly" => Some(Repeat::Yearly), _ => None } }
fn repeat_name(r: Repeat) -> &'static str { match r { Repeat::Daily => "daily", Repeat::Weekdays => "weekdays", Repeat::Weekly => "weekly", Repeat::Monthly => "monthly", Repeat::Yearly => "yearly" } }

pub fn new_id(now: i64, n: usize) -> String { format!("task-{now}-{n}") }

pub fn add_quick<Tz: TimeZone>(store: &Store, input: &str, now: &DateTime<Tz>) -> Task {
    let p = quickadd::parse(input, now);
    let due = p.due.as_ref().map(|d| d.timestamp()).or_else(|| p.repeats.map(|r| r.next(None, &(now.clone() - chrono::Duration::days(1))).timestamp()));
    let t = Task { id: new_id(now.timestamp(), store.all::<Task>("task", 100000).len()), title: p.title, notes: String::new(), due, thread_id: None, completed_at: None, created_at: now.timestamp(),
        priority: match p.priority { Priority::High => "high", Priority::Low => "low", _ => "medium" }.into(), repeats: p.repeats.map(|r| repeat_name(r).to_string()) };
    let _ = store.put("task", &t.id, due.unwrap_or(t.created_at) as f64, &t); t
}

/// Completing a repeating task schedules exactly one next occurrence in the future.
pub fn toggle<Tz: TimeZone>(store: &Store, id: &str, now: &DateTime<Tz>) -> Option<Task> {
    let mut t: Task = store.get("task", id)?;
    let completing = !t.is_done();
    t.completed_at = if completing { Some(now.timestamp()) } else { None };
    let _ = store.put("task", &t.id, t.due.unwrap_or(t.created_at) as f64, &t);
    if completing { if let Some(r) = t.repeats.as_deref().and_then(repeat_of) {
        let due = t.due.and_then(|d| now.timezone().timestamp_opt(d, 0).single());
        let next = r.next(due.as_ref(), now).timestamp();
        let n = Task { id: new_id(now.timestamp(), store.all::<Task>("task", 100000).len() + 1), completed_at: None, due: Some(next), created_at: now.timestamp(), ..t.clone() };
        let _ = store.put("task", &n.id, next as f64, &n);
    } }
    Some(t)
}

pub fn open(store: &Store) -> Vec<Task> { let mut v: Vec<Task> = store.all::<Task>("task", 100000).into_iter().filter(|t| !t.is_done()).collect(); v.sort_by_key(|t| t.due.unwrap_or(i64::MAX)); v }

static ACTIONABLE: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)(\bdue\b|deadline|expires?|expiring|overdue|action required|please (reply|confirm|sign|respond|review)|\bby (mon|tue|wed|thu|fri|sat|sun)|invoice|renewal|payment (failed|due)|final (notice|reminder))").unwrap());
/// With no AI key mail is never triaged, so deadline wording is enough to suggest a task.
pub fn looks_actionable(subject: &str, snippet: &str) -> bool { ACTIONABLE.is_match(&format!("{subject} {snippet}")) }

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{FixedOffset, Timelike};
    fn now() -> DateTime<FixedOffset> { FixedOffset::east_opt(10 * 3600).unwrap().with_ymd_and_hms(2026, 11, 5, 9, 0, 0).unwrap() }
    #[test] fn quick_add_stores_title_due_priority() {
        let s = Store::open(None).unwrap(); let t = add_quick(&s, "pay rent friday 5pm high", &now());
        assert_eq!((t.title.as_str(), t.priority.as_str()), ("pay rent", "high")); assert_eq!(chrono::DateTime::from_timestamp(t.due.unwrap(), 0).unwrap().with_timezone(&now().timezone()).hour(), 17);
        assert_eq!(open(&s).len(), 1);
    }
    #[test] fn completing_a_repeating_task_creates_exactly_one_next() {
        let s = Store::open(None).unwrap(); let t = add_quick(&s, "water plants every friday 8am", &now()); assert_eq!(t.repeats.as_deref(), Some("weekly"));
        let done = toggle(&s, &t.id, &now()).unwrap(); assert!(done.is_done());
        let open_tasks = open(&s); assert_eq!(open_tasks.len(), 1); assert!(open_tasks[0].due.unwrap() > t.due.unwrap());
        let all: Vec<Task> = s.all("task", 10); assert_eq!(all.len(), 2);
    }
    #[test] fn a_plain_task_completes_and_reopens() {
        let s = Store::open(None).unwrap(); let t = add_quick(&s, "buy milk", &now());
        assert!(toggle(&s, &t.id, &now()).unwrap().is_done()); assert!(!toggle(&s, &t.id, &now()).unwrap().is_done()); assert_eq!(open(&s).len(), 1);
    }
    #[test] fn deadline_wording_suggests_tasks_chit_chat_does_not() {
        assert!(looks_actionable("Invoice #2041 is due Friday", "") && looks_actionable("Final reminder: lease renewal", ""));
        assert!(!looks_actionable("Lunch on Sunday?", "fancy a pie"));
    }
}
