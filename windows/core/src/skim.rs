//! Seven skim-reading highlight kinds, briefing sections, speech text, and the handled-sender scrub.
use once_cell::sync::Lazy;
use regex::Regex;

static TAG: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?s)<<[uadpmnl]\|([^>]*)>>").unwrap());
static OPEN_TAG: Lazy<Regex> = Lazy::new(|| Regex::new(r"<<[uadpmnl]\|").unwrap());
pub const PROMPT_RULE: &str = "For skim reading, wrap at most ten key phrases, each under six words, in these tags: <<u|urgent>>, <<a|action to take>>, <<d|date or time>>, <<p|person or organisation>>, <<m|money>>, <<n|number or measurement>>, <<l|place>>. Never nest tags. Keep everything else plain.";

/// Text with the highlight tags removed.
pub fn strip(text: &str) -> String {
    let tagged = TAG.replace_all(text, |caps: &regex::Captures| {
        let content = &caps[1];
        if content.trim_matches(|c: char| c.is_whitespace() || c == '.' || c == '…').is_empty() { String::new() } else { content.to_string() }
    });
    OPEN_TAG.replace_all(&tagged, "").replace(">>", "")
}

#[derive(Debug, PartialEq)]
pub struct Section { pub heading: Option<String>, pub body: String }

/// Split only the supported level-two headings; an unsectioned old briefing remains readable.
pub fn sections(text: &str) -> Vec<Section> {
    let mut out = vec![];
    let (mut heading, mut body) = (None, Vec::new());
    for line in text.lines() {
        if let Some(title) = line.trim().strip_prefix("## ") {
            let joined = body.join("\n").trim().to_string();
            if !joined.is_empty() { out.push(Section { heading: heading.take(), body: joined }); }
            body.clear(); heading = Some(title.trim_matches([' ', '#', ':']).to_string());
        } else { body.push(line); }
    }
    let joined = body.join("\n").trim().to_string();
    if !joined.is_empty() { out.push(Section { heading, body: joined }); }
    out
}

/// Headings and highlight markup do not belong in spoken text or notification previews.
pub fn plain(text: &str) -> String { sections(text).into_iter().map(|s| strip(&s.body)).collect::<Vec<_>>().join("\n\n") }

/// Removes every sentence that mentions any of the names (case-insensitive, ignoring highlight tags).
/// Used after "That was me": handled senders never appear in the briefing.
pub fn removing_sentences_mentioning(names: &[&str], text: &str) -> String {
    let names: Vec<String> = names.iter().map(|n| n.to_lowercase()).filter(|n| !n.is_empty()).collect();
    if names.is_empty() { return text.to_string(); }
    sections(text).into_iter().filter_map(|s| {
        let body = s.body.lines().map(|line| {
            let (mut sentences, mut cur) = (vec![], String::new());
            for ch in line.chars() { cur.push(ch); if ".!?".contains(ch) { sentences.push(std::mem::take(&mut cur)); } }
            if !cur.is_empty() { sentences.push(cur); }
            sentences.into_iter().filter(|sentence| { let p = strip(sentence).to_lowercase(); !names.iter().any(|n| p.contains(n)) })
                .collect::<String>().trim().to_string()
        }).collect::<Vec<_>>().join("\n").trim().to_string();
        if body.is_empty() { None } else { Some(match s.heading { Some(h) => format!("## {h}\n{body}"), None => body }) }
    }).collect::<Vec<_>>().join("\n\n")
}

/// The first sentence or two of a briefing, for a notification body.
pub fn preview(text: &str, limit: usize) -> String {
    let plain = plain(text).replace('\n', " ");
    if plain.chars().count() <= limit { return plain; }
    let cut: String = plain.chars().take(limit).collect();
    match cut.rfind(|c| ".!?".contains(c)) { Some(i) => cut[..=i].to_string(), None => format!("{}…", cut.trim_end()) }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn sentences_naming_handled_senders_are_removed() {
        let old = "Update your payment details by Friday. Oscar is waiting on a reply about Thursday. Google also sent three notices today. It is 30°C.";
        assert_eq!(removing_sentences_mentioning(&["Google", "Google One"], old),
            "Update your payment details by Friday. Oscar is waiting on a reply about Thursday. It is 30°C.");
    }
    #[test] fn tags_are_ignored_when_matching() {
        assert_eq!(removing_sentences_mentioning(&["google"], "<<u|Google One>> payment is due. Oscar needs you."), "Oscar needs you.");
    }
    #[test] fn notification_preview_drops_tags_and_ends_on_a_sentence() {
        let t = "<<u|Pay rent>> by <<d|Friday>>. Oscar needs a reply about the Thursday roadmap sync and wants the agenda confirmed before the meeting starts later today at noon.";
        assert_eq!(preview(t, 60), "Pay rent by Friday.");
    }
    #[test] fn all_seven_kinds_and_unfinished_tags_are_cleaned() {
        assert_eq!(strip("<<u|urgent>> <<a|reply>> <<d|Friday>> <<p|Oscar>> <<m|$20>> <<n|31°C>> <<l|Cairns>>"), "urgent reply Friday Oscar $20 31°C Cairns");
        assert_eq!(strip("Done <<u|...>> <<d|…>> <<a|reply"), "Done   reply");
    }
    #[test] fn sections_survive_scrubbing_and_empty_headings_are_removed() {
        let text = "## Needs you\n<<a|Reply to Oscar>>. Google sent an alert.\n\n## Today\nGoogle again.\n\n## News\nSolar grew.";
        assert_eq!(removing_sentences_mentioning(&["Google"], text), "## Needs you\n<<a|Reply to Oscar>>.\n\n## News\nSolar grew.");
    }
    #[test] fn speech_and_notifications_skip_headings_and_every_tag_kind() {
        let text = "## Needs you\n<<a|Reply to Oscar>>.\n\n## News\nSolar grew.";
        assert_eq!(plain(text), "Reply to Oscar.\n\nSolar grew.");
        assert_eq!(preview(text, 16), "Reply to Oscar.");
        assert!(sections("## Empty").is_empty());
    }
}
