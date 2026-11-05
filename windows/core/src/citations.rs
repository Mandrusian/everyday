//! Assistant citations: tags like [M1] or [N2, M1] in the reply become numbered sources, in order of first appearance.
use once_cell::sync::Lazy;
use regex::Regex;

#[derive(Debug, Clone, PartialEq)]
pub struct Source { pub tag: String, pub title: String, pub kind: Kind, pub reference: String }
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Kind { Mail, News }

static TAGS: Lazy<Regex> = Lazy::new(|| Regex::new(r"\s?\[((?:[MN]\d+)(?:\s*,\s*[MN]\d+)*)\]").unwrap());

pub fn resolve(text: &str, sources: &[Source]) -> (String, Vec<Source>) {
    let mut cited: Vec<Source> = vec![];
    for m in TAGS.captures_iter(text) {
        for tag in m[1].split(',').map(str::trim) {
            if let Some(s) = sources.iter().find(|s| s.tag == tag) { if !cited.contains(s) { cited.push(s.clone()); } }
        }
    }
    (TAGS.replace_all(text, "").to_string(), cited)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn s(tag: &str, kind: Kind) -> Source { Source { tag: tag.into(), title: tag.into(), kind, reference: "r".into() } }
    #[test] fn resolves_in_order_ignores_unknown_and_cleans() {
        let src = vec![s("M1", Kind::Mail), s("N2", Kind::News), s("M3", Kind::Mail)];
        let (text, cited) = resolve("Dana wants a reply [M1]. Solar is up [N2, M1] and nothing else [M9].", &src);
        assert_eq!(cited.iter().map(|c| c.tag.as_str()).collect::<Vec<_>>(), ["M1", "N2"]);
        assert_eq!(text, "Dana wants a reply. Solar is up and nothing else.");
    }
}
