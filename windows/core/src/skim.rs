//! Skim-reading markup (`<<u|…>>` urgent, `<<d|…>>` date, `<<p|…>>` person, `<<n|…>>` number) and the briefing scrub.
use once_cell::sync::Lazy;
use regex::Regex;

static TAG: Lazy<Regex> = Lazy::new(|| Regex::new(r"<<[udpn]\|([^>]*)>>").unwrap());

/// Text with the highlight tags removed.
pub fn strip(text: &str) -> String { TAG.replace_all(text, "$1").to_string() }

/// Removes every sentence that mentions any of the names (case-insensitive, ignoring highlight tags).
/// Used after "That was me": handled senders never appear in the briefing.
pub fn removing_sentences_mentioning(names: &[&str], text: &str) -> String {
    let names: Vec<String> = names.iter().map(|n| n.to_lowercase()).filter(|n| !n.is_empty()).collect();
    if names.is_empty() { return text.to_string(); }
    let (mut sentences, mut cur) = (vec![], String::new());
    for ch in text.chars() { cur.push(ch); if ".!?".contains(ch) { sentences.push(std::mem::take(&mut cur)); } }
    if !cur.is_empty() { sentences.push(cur); }
    sentences.into_iter().filter(|s| { let p = strip(s).to_lowercase(); !names.iter().any(|n| p.contains(n)) })
        .collect::<String>().trim().to_string()
}

/// The first sentence or two of a briefing, for a notification body.
pub fn preview(text: &str, limit: usize) -> String {
    let plain = strip(text).replace('\n', " ");
    if plain.chars().count() <= limit { return plain; }
    let cut: String = plain.chars().take(limit).collect();
    match cut.rfind(|c| ".!?".contains(c)) { Some(i) => cut[..=i].to_string(), None => format!("{}…", cut.trim_end()) }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn sentences_naming_handled_senders_are_removed() {
        let old = "Update your payment details by Friday. Dana is waiting on a reply about Thursday. Google also sent three notices today. It is 30°C.";
        assert_eq!(removing_sentences_mentioning(&["Google", "Google One"], old),
            "Update your payment details by Friday. Dana is waiting on a reply about Thursday. It is 30°C.");
    }
    #[test] fn tags_are_ignored_when_matching() {
        assert_eq!(removing_sentences_mentioning(&["google"], "<<u|Google One>> payment is due. Dana needs you."), "Dana needs you.");
    }
    #[test] fn notification_preview_drops_tags_and_ends_on_a_sentence() {
        let t = "<<u|Pay rent>> by <<d|Friday>>. Dana needs a reply about the Thursday roadmap sync and wants the agenda confirmed before the meeting starts later today at noon.";
        assert_eq!(preview(t, 60), "Pay rent by Friday.");
    }
}
