//! News: feed parsing, promo filtering, muted topics, clustering of near-duplicate headlines, and ranking. Ported from `NewsService`.
use once_cell::sync::Lazy;
use regex::Regex;
use std::collections::HashSet;

#[derive(Debug, Clone, PartialEq)]
pub struct Article { pub id: String, pub title: String, pub summary: String, pub source: String, pub url: String, pub published: i64, pub trust: i32, pub outside_bubble: bool }

#[derive(Debug, Clone)]
pub struct Story { pub lead: Article, pub others: Vec<Article>, pub score: f64 }

/// Coupon, promo-code and deal-roundup headlines are advertising, not news.
static PROMO: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)(coupon|promo(tion(al)?)? codes?|discount codes?|voucher|\d+% off|\bdeals? (of the|on)\b|best .{0,30}\bdeals\b|black friday|cyber monday|prime day|sale ends|gift guide|where to buy)").unwrap());
pub fn is_promo(title: &str) -> bool { PROMO.is_match(title) }

const STOPWORDS: &[&str] = &["the", "and", "for", "with", "that", "this", "from", "are", "was", "were", "has", "have", "had", "its", "about", "after", "over", "into", "new", "says", "say", "how", "why", "what", "who", "will", "can", "not", "but", "you", "your", "his", "her", "their"];

pub fn title_tokens(t: &str) -> HashSet<String> {
    t.to_lowercase().split(|c: char| !c.is_alphanumeric()).filter(|w| w.chars().count() > 2 && !STOPWORDS.contains(w)).map(String::from).collect()
}

pub fn similar(a: &HashSet<String>, b: &HashSet<String>) -> bool {
    if a.is_empty() || b.is_empty() { return false; }
    let inter = a.intersection(b).count() as f64;
    let jaccard = inter / a.union(b).count() as f64;
    let overlap = inter / a.len().min(b.len()) as f64;
    jaccard >= 0.45 || (overlap >= 0.75 && inter >= 4.0)
}

pub struct Options { pub freshness_hours: f64, pub muted: Vec<String>, pub followed: Vec<String>, pub topic: Option<String>, pub hide_promos: bool, pub include_outside: bool, pub limit: usize }
impl Default for Options { fn default() -> Self { Options { freshness_hours: 48.0, muted: vec![], followed: vec![], topic: None, hide_promos: true, include_outside: true, limit: 60 } } }

/// JSON lists preserve commas in a topic. Accept older comma-separated preferences too.
pub fn topic_list(raw: &str) -> Vec<String> {
    let values: Vec<String> = serde_json::from_str(raw).unwrap_or_else(|_| raw.split(',').map(String::from).collect());
    let mut seen = HashSet::new();
    values.into_iter().map(|v| v.trim().to_string()).filter(|v| !v.is_empty() && seen.insert(v.to_lowercase())).collect()
}

/// Fresh, de-duplicated, ranked stories. `interest` scores an article from the reader's learned tastes.
pub fn stories(mut arts: Vec<Article>, now: i64, opt: &Options, interest: &dyn Fn(&Article) -> f64) -> Vec<Story> {
    let cutoff = now - (opt.freshness_hours * 3600.0) as i64;
    let muted: Vec<String> = opt.muted.iter().map(|m| m.to_lowercase()).filter(|m| !m.is_empty()).collect();
    arts.retain(|a| a.published >= cutoff);
    if !muted.is_empty() { arts.retain(|a| { let t = format!("{} {}", a.title, a.summary).to_lowercase(); !muted.iter().any(|m| t.contains(m)) }); }
    if let Some(topic) = opt.topic.as_ref().map(|t| t.trim().to_lowercase()).filter(|t| !t.is_empty()) {
        arts.retain(|a| format!("{} {}", a.title, a.summary).to_lowercase().contains(&topic));
    }
    if opt.hide_promos { arts.retain(|a| !is_promo(&a.title)); }
    arts.sort_by(|a, b| b.published.cmp(&a.published));

    struct Cluster { lead: Article, tokens: HashSet<String>, others: Vec<Article> }
    let mut clusters: Vec<Cluster> = vec![];
    for a in arts {
        let t = title_tokens(&a.title);
        if let Some(c) = clusters.iter_mut().find(|c| similar(&c.tokens, &t)) {
            c.tokens.extend(t);
            if a.trust > c.lead.trust { let old = std::mem::replace(&mut c.lead, a.clone()); c.others.push(old); } else { c.others.push(a); }
        } else { clusters.push(Cluster { lead: a, tokens: t, others: vec![] }); }
    }
    let mut out: Vec<Story> = clusters.into_iter().map(|c| {
        let age_h = ((now - c.lead.published) as f64 / 3600.0).max(0.0);
        let recency = (-age_h / 18.0).exp();
        let coverage = ((1 + c.others.len()) as f64).log2() * 0.6;
        let trust = (c.lead.trust - 2) as f64 * 0.3;
        let text = format!("{} {}", c.lead.title, c.lead.summary).to_lowercase();
        let follow = if opt.followed.iter().any(|t| !t.trim().is_empty() && text.contains(&t.trim().to_lowercase())) { 2.5 } else { 0.0 };
        let score = interest(&c.lead) * 0.5 + recency * 3.0 + coverage + trust + follow;
        Story { lead: c.lead, others: c.others, score }
    }).collect();
    out.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal));
    let mut main: Vec<Story> = out.iter().filter(|s| !s.lead.outside_bubble).cloned().collect();
    if opt.include_outside {   // keep roughly one in ten slots for sources outside the reader's usual bubble
        let slots = (opt.limit / 10).max(1);
        for (i, s) in out.iter().filter(|s| s.lead.outside_bubble).take(slots).enumerate() {
            let pos = main.len().min(4 + i * 9); main.insert(pos, s.clone());
        }
    }
    main.truncate(opt.limit);
    main
}

/// RSS or Atom text into articles for one source.
pub fn parse_feed(xml: &[u8], source: &str, trust: i32, outside_bubble: bool) -> Vec<Article> {
    let Ok(feed) = feed_rs::parser::parse(xml) else { return vec![] };
    feed.entries.into_iter().filter_map(|e| {
        let title = e.title.map(|t| t.content.trim().to_string()).filter(|t| !t.is_empty())?;
        let url = e.links.first().map(|l| l.href.clone())?;
        let summary = e.summary.map(|s| strip_html(&s.content)).or_else(|| e.content.and_then(|c| c.body).map(|b| strip_html(&b))).unwrap_or_default();
        let published = e.published.or(e.updated).map(|d| d.timestamp())?;
        Some(Article { id: article_id(&url), title, summary: summary.chars().take(400).collect(), source: source.into(), url, published, trust, outside_bubble })
    }).collect()
}

static TAGS: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?s)<[^>]*>").unwrap());
fn strip_html(s: &str) -> String {
    let t = TAGS.replace_all(s, " ").replace("&amp;", "&").replace("&nbsp;", " ").replace("&quot;", "\"").replace("&#39;", "'").replace("&lt;", "<").replace("&gt;", ">");
    t.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Stable id from the link (FNV-1a, hex).
pub fn article_id(link: &str) -> String {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in link.trim().to_lowercase().bytes() { h ^= b as u64; h = h.wrapping_mul(0x100000001b3); }
    format!("{:016x}", h)
}

#[cfg(test)]
mod tests {
    use super::*;
    const NOW: i64 = 1_800_000_000;
    fn a(id: &str, title: &str, hours_ago: i64, trust: i32) -> Article { Article { id: id.into(), title: title.into(), summary: String::new(), source: "s".into(), url: format!("https://x/{id}"), published: NOW - hours_ago * 3600, trust, outside_bubble: false } }
    #[test] fn followed_topics_lift_stories_but_muting_takes_priority() {
        let arts = vec![a("1", "Aviation fuel efficiency improves", 10, 3), a("2", "Tennis final tonight preview", 1, 3)];
        let mut opt = Options { followed: vec!["AVIATION".into()], ..Options::default() };
        assert_eq!(stories(arts.clone(), NOW, &opt, &|_| 0.0)[0].lead.id, "1");
        opt.muted = vec!["aviation".into()];
        assert_eq!(stories(arts.clone(), NOW, &opt, &|_| 0.0)[0].lead.id, "2");
        opt.muted.clear(); opt.topic = Some("aviation".into());
        assert_eq!(stories(arts, NOW, &opt, &|_| 0.0).len(), 1);
        assert_eq!(topic_list(r#"[" Washington, DC ", "Rust", "rust", ""]"#), ["Washington, DC", "Rust"]);
        assert_eq!(topic_list(" Rust, aviation "), ["Rust", "aviation"]);
    }
    #[test] fn promo_headlines_are_filtered_real_news_is_not() {
        assert!(is_promo("Udemy Coupon Codes: 20% Off November 2026") && is_promo("Corsair Discount Code: Up to 50% Off") && is_promo("The best laptop deals of the week"));
        assert!(!is_promo("Uranium cubes reveal why the German nuclear project failed") && !is_promo("Open-source models close the gap"));
    }
    #[test] fn near_duplicate_headlines_become_one_story_led_by_the_most_trusted() {
        let arts = vec![a("1", "Reserve Bank holds interest rates steady at 3.6 percent", 2, 2), a("2", "RBA holds interest rates steady at 3.6 percent", 3, 4), a("3", "Solar installs hit a record in Australia", 1, 3)];
        let s = stories(arts, NOW, &Options::default(), &|_| 0.0);
        assert_eq!(s.len(), 2);
        let rates = s.iter().find(|x| x.lead.title.contains("interest")).unwrap();
        assert_eq!((rates.lead.id.as_str(), rates.others.len()), ("2", 1));
    }
    #[test] fn old_muted_and_promo_stories_are_dropped() {
        let arts = vec![a("1", "Old news", 100, 3), a("2", "Hong Kong court sentences activist", 1, 3), a("3", "Meta Quest Promo Codes for November", 1, 3), a("4", "Chip makers report record quarter", 1, 3)];
        let opt = Options { muted: vec!["hong kong".into()], ..Options::default() };
        let s = stories(arts, NOW, &opt, &|_| 0.0);
        assert_eq!(s.iter().map(|x| x.lead.id.as_str()).collect::<Vec<_>>(), ["4"]);
    }
    #[test] fn interest_and_recency_drive_ranking() {
        let arts = vec![a("1", "Tennis final tonight preview", 1, 3), a("2", "Quantum computer error rates fall sharply", 1, 3)];
        let s = stories(arts, NOW, &Options::default(), &|x| if x.title.contains("Quantum") { 5.0 } else { 0.0 });
        assert_eq!(s[0].lead.id, "2");
    }
    #[test] fn rss_and_atom_parse() {
        let rss = br#"<?xml version="1.0"?><rss version="2.0"><channel><title>T</title><item><title>Solar record</title><link>https://x.test/solar</link><description>&lt;p&gt;Rooftop &amp;amp; more&lt;/p&gt;</description><pubDate>Tue, 03 Nov 2026 01:00:00 GMT</pubDate></item></channel></rss>"#;
        let r = parse_feed(rss, "Test", 3, false);
        assert_eq!((r.len(), r[0].title.as_str()), (1, "Solar record")); assert!(!r[0].summary.contains('<'));
        let atom = br#"<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom"><title>A</title><id>x</id><updated>2026-11-03T01:00:00Z</updated><entry><title>Reef bounces back</title><id>1</id><link href="https://x.test/reef"/><updated>2026-11-03T01:00:00Z</updated><summary>Good news</summary></entry></feed>"#;
        assert_eq!(parse_feed(atom, "A", 3, false)[0].url, "https://x.test/reef");
    }
    #[test] fn article_ids_are_stable() { assert_eq!(article_id("https://x/1"), article_id(" HTTPS://X/1 ")); assert_ne!(article_id("a"), article_id("b")); }
}
