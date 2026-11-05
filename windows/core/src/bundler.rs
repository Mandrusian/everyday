//! Repeated automated mail (security alerts, receipts) from one sender is grouped into a bundle; people are never grouped.
use once_cell::sync::Lazy;
use regex::Regex;

static AUTOMATED_LOCAL: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)^(no[-_.]?reply|do[-_.]?not[-_.]?reply|notifications?|alerts?|security|mailer|mailer-daemon|updates?|news|newsletter|hello|team|info|support|billing|receipts?|orders?|account|accounts|noreply)").unwrap());

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Category { Important, NeedsReply, Deadline, ActionItem, Newsletter, Promo, SpamSuspect, Fyi }

/// True for mail sent by a system rather than a person.
pub fn is_automated(from_address: &str, category: Option<Category>) -> bool {
    if matches!(category, Some(Category::Newsletter) | Some(Category::Promo)) { return true; }
    let local = from_address.split('@').next().unwrap_or("");
    AUTOMATED_LOCAL.is_match(local)
}

/// Registrable-ish domain: accounts.google.com → google.com, mail.example.com.au → example.com.au
pub fn domain_key(address: &str) -> String {
    let host = address.rsplit('@').next().unwrap_or(address).to_lowercase();
    let parts: Vec<&str> = host.split('.').collect();
    if parts.len() <= 2 { return host; }
    let sld = ["com", "co", "org", "net", "gov", "edu"];
    let n = parts.len();
    if sld.contains(&parts[n - 2]) && parts[n - 1].len() == 2 { parts[n - 3..].join(".") } else { parts[n - 2..].join(".") }
}

#[derive(Debug, Clone)]
pub struct Row { pub thread_id: String, pub from_address: String, pub category: Option<Category> }

/// Thread ids that "That was me" should cover: the pressed ones plus every conversation from the same automated sender group.
pub fn expanded_thread_ids(pressed: &[String], rows: &[Row]) -> Vec<String> {
    let mut keys = std::collections::HashSet::new();
    for id in pressed { if let Some(r) = rows.iter().find(|r| &r.thread_id == id) { if is_automated(&r.from_address, r.category) { keys.insert(domain_key(&r.from_address)); } } }
    let mut out: std::collections::BTreeSet<String> = pressed.iter().cloned().collect();
    for r in rows { if is_automated(&r.from_address, r.category) && keys.contains(&domain_key(&r.from_address)) { out.insert(r.thread_id.clone()); } }
    out.into_iter().collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn domain_keys() {
        assert_eq!(domain_key("no-reply@accounts.google.com"), "google.com");
        assert_eq!(domain_key("a@mail.example.com.au"), "example.com.au");
        assert_eq!(domain_key("dana@acme.com"), "acme.com");
    }
    #[test] fn automated_senders_are_detected_people_are_not() {
        assert!(is_automated("no-reply@accounts.google.com", None)); assert!(is_automated("noreply@google.com", None));
        assert!(!is_automated("dana@acme.com.au", None)); assert!(is_automated("dana@acme.com", Some(Category::Newsletter)));
    }
    #[test] fn that_was_me_covers_the_whole_google_group_but_not_people() {
        let row = |t: &str, a: &str| Row { thread_id: t.into(), from_address: a.into(), category: Some(Category::Important) };
        let rows = vec![row("gt1", "no-reply@accounts.google.com"), row("gt2", "no-reply@accounts.google.com"), row("gt3", "noreply@google.com"),
                        row("gt4", "no-reply@accounts.google.com"), row("dt1", "dana@acme.com.au")];
        assert_eq!(expanded_thread_ids(&["gt1".into()], &rows), ["gt1", "gt2", "gt3", "gt4"]);
        assert_eq!(expanded_thread_ids(&["dt1".into()], &rows), ["dt1"]);
    }
}
