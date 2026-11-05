//! On-device preference model, ported from `InterestModel`: learns from swipes, reads and saves with per-category, per-source and
//! per-keyword weights that fade with a 45-day half-life. Nothing leaves the computer. (Keywords come from a plain word split, where
//! the Mac app uses Apple's part-of-speech tagger.)
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashSet};

const HALF_LIFE_DAYS: f64 = 45.0;
const STOPWORDS: &[&str] = &["that", "this", "with", "from", "have", "will", "your", "about", "after", "over", "more", "than", "what", "when", "they", "their", "says", "said", "could", "would", "should", "into", "been", "were", "also", "just", "like", "year", "years", "week", "today", "news", "here", "there", "them", "then", "some", "much", "most", "many", "other", "first", "back", "still", "even", "only", "make", "made", "does", "doing", "being", "because", "while", "where", "which", "against", "between"];

#[derive(Serialize, Deserialize, Debug, Clone, Default, PartialEq)]
pub struct Profile {
    pub category_weights: BTreeMap<String, f64>, pub source_weights: BTreeMap<String, f64>, pub keyword_weights: BTreeMap<String, f64>,
    pub updated_at: i64, pub reaction_count: u32,
}

pub fn tokens(text: &str) -> Vec<String> {
    text.to_lowercase().split(|c: char| !c.is_alphanumeric()).filter(|w| w.chars().count() > 3 && !STOPWORDS.contains(w)).map(String::from).collect()
}

impl Profile {
    /// Older reactions count less: every weight halves every 45 days, and tiny keyword weights are dropped.
    pub fn decay(&mut self, now: i64) {
        let days = (now - self.updated_at) as f64 / 86400.0;
        if days <= 0.5 { return; }
        let f = 0.5f64.powf(days / HALF_LIFE_DAYS);
        for v in self.category_weights.values_mut().chain(self.source_weights.values_mut()) { *v *= f; }
        for v in self.keyword_weights.values_mut() { *v *= f; }
        self.keyword_weights.retain(|_, v| v.abs() > 0.05);
        self.updated_at = now;
    }
    /// Onboarding: the topics picked in the first swipe deck start with a head start.
    pub fn seed(&mut self, categories: &[&str]) { for c in categories { *self.category_weights.entry(c.to_string()).or_insert(0.0) += 2.0; } }

    /// `reaction`: +2 love, +1 like, -1 not interested, small positives for reading or saving.
    pub fn record(&mut self, categories: &[String], source: &str, title: &str, reaction: f64, now: i64) {
        self.decay(now);
        for c in categories { *self.category_weights.entry(c.clone()).or_insert(0.0) += reaction * 0.8; }
        *self.source_weights.entry(source.to_string()).or_insert(0.0) += reaction * 0.5;
        let uniq: HashSet<String> = tokens(title).into_iter().collect(); let mut keys: Vec<String> = uniq.into_iter().collect(); keys.sort();
        for k in keys.into_iter().take(8) { *self.keyword_weights.entry(k).or_insert(0.0) += reaction * 0.4; }
        self.reaction_count += 1; self.updated_at = now;
    }

    pub fn score(&self, categories: &[String], source: &str, title: &str) -> f64 {
        let mut s: f64 = categories.iter().map(|c| self.category_weights.get(c).copied().unwrap_or(0.0)).sum();
        s += self.source_weights.get(source).copied().unwrap_or(0.0);
        let uniq: HashSet<String> = tokens(title).into_iter().collect();
        for k in uniq { s += self.keyword_weights.get(&k).copied().unwrap_or(0.0).min(2.0) * 0.6; }
        s
    }

    pub fn top_interests(&self, n: usize) -> Vec<(String, f64)> {
        let mut v: Vec<(String, f64)> = self.category_weights.iter().map(|(k, w)| (k.clone(), *w)).collect();
        v.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal)); v.truncate(n); v
    }
    pub fn export_json(&self) -> String { serde_json::to_string_pretty(self).unwrap_or_default() }
    pub fn import_json(s: &str) -> Result<Profile, String> { serde_json::from_str(s).map_err(|e| e.to_string()) }
}

#[cfg(test)]
mod tests {
    use super::*;
    const DAY: i64 = 86400;
    fn cats(c: &[&str]) -> Vec<String> { c.iter().map(|x| x.to_string()).collect() }
    #[test] fn liking_raises_similar_stories_disliking_lowers_them() {
        let mut p = Profile::default();
        p.record(&cats(&["ai"]), "Ars", "Quantum computer error rates fall sharply", 1.0, 0);
        p.record(&cats(&["sport"]), "ESPN", "Tennis final tonight preview", -1.0, 0);
        assert!(p.score(&cats(&["ai"]), "Ars", "Quantum chips reach new milestone") > 0.0);
        assert!(p.score(&cats(&["sport"]), "ESPN", "Tennis final tonight") < 0.0);
        assert!(p.score(&cats(&["ai"]), "Ars", "Quantum chips") > p.score(&cats(&["ai"]), "Other", "Cooking show"));
    }
    #[test] fn weights_halve_every_45_days() {
        let mut p = Profile::default(); p.record(&cats(&["ai"]), "Ars", "Quantum computers", 2.0, 0);
        let before = p.category_weights["ai"]; p.decay(45 * DAY);
        assert!((p.category_weights["ai"] - before / 2.0).abs() < 1e-9);
        p.decay(45 * DAY + 3600); assert!((p.category_weights["ai"] - before / 2.0).abs() < 1e-6);     // under half a day: no change
    }
    #[test] fn tiny_keyword_weights_are_dropped_after_long_idleness() {
        let mut p = Profile::default(); p.record(&cats(&["ai"]), "Ars", "Quantum computers", 0.5, 0); p.decay(400 * DAY); assert!(p.keyword_weights.is_empty());
    }
    #[test] fn the_keyword_bonus_is_capped_and_stopwords_are_ignored() {
        assert!(!tokens("What about this news today").contains(&"what".to_string()));
        let mut p = Profile::default(); for _ in 0..40 { p.record(&[], "s", "Quantum", 2.0, 0); }
        assert!(p.score(&[], "zzz", "Quantum") <= 2.0 * 0.6 + 1e-9);
    }
    #[test] fn onboarding_seed_gives_the_chosen_topics_a_head_start_and_top_interests_orders_them() {
        let mut p = Profile::default(); p.seed(&["technology", "ai"]); p.record(&cats(&["ai"]), "x", "y", 1.0, 0);
        assert_eq!(p.top_interests(2)[0].0, "ai"); assert_eq!(p.top_interests(1).len(), 1);
    }
    #[test] fn the_profile_survives_export_and_import() {
        let mut p = Profile::default(); p.record(&cats(&["ai"]), "Ars", "Quantum computers", 1.0, 5);
        assert_eq!(Profile::import_json(&p.export_json()).unwrap(), p); assert!(Profile::import_json("nope").is_err());
    }
}
