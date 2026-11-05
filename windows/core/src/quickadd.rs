//! Quick-add: "pay rent friday 5pm high" and "water plants every friday 8am" become a task. Parsed on the device, no AI.
use crate::repeat::Repeat;
use chrono::{DateTime, Datelike, Days, Duration, NaiveDate, NaiveTime, TimeZone, Weekday};
use once_cell::sync::Lazy;
use regex::Regex;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Priority { Low, Medium, High }

#[derive(Debug, Clone, PartialEq)]
pub struct Parsed<Tz: TimeZone> { pub title: String, pub due: Option<DateTime<Tz>>, pub priority: Priority, pub repeats: Option<Repeat> }

fn re(p: &str) -> Regex { Regex::new(p).unwrap() }
static HIGH: Lazy<Regex> = Lazy::new(|| re(r"(?i)(?:^|\s)(?:!{3}|urgent|asap|high(?: priority)?)(?:\s|$)"));
static LOW: Lazy<Regex> = Lazy::new(|| re(r"(?i)(?:^|\s)(?:low(?: priority)?|someday)(?:\s|$)"));
static REPEATS: Lazy<Vec<(Regex, Repeat)>> = Lazy::new(|| vec![
    (re(r"(?i)\bevery\s+weekday\b"), Repeat::Weekdays), (re(r"(?i)\b(?:every\s+day|daily)\b"), Repeat::Daily),
    (re(r"(?i)\b(?:every\s+week|weekly)\b"), Repeat::Weekly), (re(r"(?i)\b(?:every\s+month|monthly)\b"), Repeat::Monthly),
    (re(r"(?i)\b(?:every\s+year|yearly|annually)\b"), Repeat::Yearly)]);
static EVERY_DAYNAME: Lazy<Regex> = Lazy::new(|| re(r"(?i)\bevery\s+((?:mon|tues|wednes|thurs|fri|satur|sun)day)\b"));
static IN_N: Lazy<Regex> = Lazy::new(|| re(r"(?i)\bin\s+(\d+)\s*(minute|min|hour|hr|day|week)s?\b"));
static WEEKDAY: Lazy<Regex> = Lazy::new(|| re(r"(?i)\b(?:next\s+|this\s+|on\s+)?(mon|tues|wednes|thurs|fri|satur|sun)day\b"));
static DAYWORD: Lazy<Regex> = Lazy::new(|| re(r"(?i)\b(today|tomorrow|tonight)\b"));
static DATE_DM: Lazy<Regex> = Lazy::new(|| re(r"(?i)\b(?:on\s+)?(\d{1,2})(?:st|nd|rd|th)?\s+(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\b"));
static DATE_MD: Lazy<Regex> = Lazy::new(|| re(r"(?i)\b(?:on\s+)?(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\s+(\d{1,2})(?:st|nd|rd|th)?\b"));
static TIME_AMPM: Lazy<Regex> = Lazy::new(|| re(r"(?i)\b(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s?(am|pm)\b"));
static TIME_24: Lazy<Regex> = Lazy::new(|| re(r"\b(?:at\s+)?(\d{1,2}):(\d{2})\b"));
static TIME_WORD: Lazy<Regex> = Lazy::new(|| re(r"(?i)\b(?:at\s+)?(noon|midnight|morning|afternoon|evening)\b"));

fn weekday(prefix: &str) -> Weekday {
    match prefix.to_lowercase().as_str() { "mon" => Weekday::Mon, "tues" => Weekday::Tue, "wednes" => Weekday::Wed, "thurs" => Weekday::Thu, "fri" => Weekday::Fri, "satur" => Weekday::Sat, _ => Weekday::Sun }
}
fn month(p: &str) -> u32 { ["jan","feb","mar","apr","may","jun","jul","aug","sep","oct","nov","dec"].iter().position(|m| p.to_lowercase().starts_with(m)).map(|i| i as u32 + 1).unwrap_or(1) }

fn cut(text: &mut String, r: std::ops::Range<usize>) { text.replace_range(r, " "); }

pub fn parse<Tz: TimeZone>(input: &str, now: &DateTime<Tz>) -> Parsed<Tz> {
    let mut text = input.trim().to_string();
    let mut priority = Priority::Medium;
    if let Some(r) = HIGH.find(&text).map(|m| m.range()) { priority = Priority::High; cut(&mut text, r); }
    else if let Some(r) = LOW.find(&text).map(|m| m.range()) { priority = Priority::Low; cut(&mut text, r); }

    let mut repeats = None;
    for (rx, k) in REPEATS.iter() { if let Some(r) = rx.find(&text).map(|m| m.range()) { repeats = Some(*k); cut(&mut text, r); break; } }
    if repeats.is_none() { if let Some((r, day)) = EVERY_DAYNAME.captures(&text).map(|c| (c.get(0).unwrap().range(), c[1].to_string())) { repeats = Some(Repeat::Weekly); text.replace_range(r, &format!(" {day} ")); } }

    // time of day
    let mut time: Option<NaiveTime> = None;
    if let Some(c) = TIME_AMPM.captures(&text) {
        let (h, mi, ap) = (c[1].parse::<u32>().unwrap_or(0), c.get(2).map_or(0, |x| x.as_str().parse().unwrap_or(0)), c[3].to_lowercase());
        let h24 = match (h % 12, ap.as_str()) { (x, "pm") => x + 12, (x, _) => x };
        time = NaiveTime::from_hms_opt(h24, mi, 0); let r = c.get(0).unwrap().range(); cut(&mut text, r);
    } else if let Some(c) = TIME_24.captures(&text) {
        time = NaiveTime::from_hms_opt(c[1].parse().unwrap_or(99), c[2].parse().unwrap_or(99), 0); let r = c.get(0).unwrap().range(); cut(&mut text, r);
    } else if let Some(c) = TIME_WORD.captures(&text) {
        time = match c[1].to_lowercase().as_str() { "noon" => NaiveTime::from_hms_opt(12, 0, 0), "midnight" => NaiveTime::from_hms_opt(0, 0, 0), "morning" => NaiveTime::from_hms_opt(9, 0, 0), "afternoon" => NaiveTime::from_hms_opt(15, 0, 0), _ => NaiveTime::from_hms_opt(18, 0, 0) };
        let r = c.get(0).unwrap().range(); cut(&mut text, r);
    }

    // date
    let tz = now.timezone();
    let today = now.date_naive();
    let mut date: Option<NaiveDate> = None;
    let mut relative: Option<DateTime<Tz>> = None;
    if let Some(c) = IN_N.captures(&text) {
        let n: i64 = c[1].parse().unwrap_or(1);
        let delta = match c[2].to_lowercase().as_str() { "minute" | "min" => Duration::minutes(n), "hour" | "hr" => Duration::hours(n), "day" => Duration::days(n), _ => Duration::weeks(n) };
        relative = Some(now.clone() + delta); let r = c.get(0).unwrap().range(); cut(&mut text, r);
    } else if let Some(c) = DAYWORD.captures(&text) {
        let w = c[1].to_lowercase();
        date = Some(if w == "tomorrow" { today.checked_add_days(Days::new(1)).unwrap_or(today) } else { today });
        if w == "tonight" && time.is_none() { time = NaiveTime::from_hms_opt(20, 0, 0); }
        let r = c.get(0).unwrap().range(); cut(&mut text, r);
    } else if let Some(c) = WEEKDAY.captures(&text) {
        let target = weekday(&c[1]);
        let ahead = (7 + target.num_days_from_monday() as i64 - today.weekday().num_days_from_monday() as i64) % 7;
        date = today.checked_add_days(Days::new(ahead as u64));
        let r = c.get(0).unwrap().range(); cut(&mut text, r);
    } else if let Some(c) = DATE_DM.captures(&text) {
        let (d, mo) = (c[1].parse().unwrap_or(1), month(&c[2]));
        date = ymd_future(today, mo, d); let r = c.get(0).unwrap().range(); cut(&mut text, r);
    } else if let Some(c) = DATE_MD.captures(&text) {
        let (mo, d) = (month(&c[1]), c[2].parse().unwrap_or(1));
        date = ymd_future(today, mo, d); let r = c.get(0).unwrap().range(); cut(&mut text, r);
    }

    let due = if let Some(r) = relative { Some(r) } else {
        match (date, time) {
            (Some(d), Some(t)) => tz.from_local_datetime(&d.and_time(t)).single(),
            (Some(d), None) => tz.from_local_datetime(&d.and_time(NaiveTime::MIN)).single(),
            (None, Some(t)) => {   // only a time: today if it is still ahead, otherwise tomorrow
                let todays = tz.from_local_datetime(&today.and_time(t)).single();
                match todays { Some(x) if x > *now => Some(x), _ => today.checked_add_days(Days::new(1)).and_then(|d| tz.from_local_datetime(&d.and_time(t)).single()) }
            }
            (None, None) => None,
        }
    };

    let dangling = re(r"(?i)\s+(on|by|at|for|due)\s*$");
    let cleaned = dangling.replace(&re(r"\s{2,}").replace_all(&text, " "), "").trim().to_string();
    let title = if cleaned.is_empty() { input.trim().to_string() } else { cleaned };
    Parsed { title, due, priority, repeats }
}

fn ymd_future(today: NaiveDate, month: u32, day: u32) -> Option<NaiveDate> {
    let this = NaiveDate::from_ymd_opt(today.year(), month, day)?;
    if this >= today { Some(this) } else { NaiveDate::from_ymd_opt(today.year() + 1, month, day) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{FixedOffset, Timelike};
    fn now() -> DateTime<FixedOffset> { FixedOffset::east_opt(10 * 3600).unwrap().with_ymd_and_hms(2026, 11, 5, 9, 0, 0).unwrap() } // Thursday
    #[test] fn pay_rent_friday_5pm_high() {
        let p = parse("pay rent friday 5pm high", &now());
        assert_eq!(p.title, "pay rent"); assert_eq!(p.priority, Priority::High);
        let d = p.due.unwrap(); assert_eq!((d.weekday(), d.hour(), d.day()), (Weekday::Fri, 17, 6));
    }
    #[test] fn weekly_repeat_from_a_weekday_name() {
        let p = parse("water plants every friday 8am", &now());
        assert_eq!(p.title, "water plants"); assert_eq!(p.repeats, Some(Repeat::Weekly));
        let d = p.due.unwrap(); assert_eq!((d.weekday(), d.hour()), (Weekday::Fri, 8));
    }
    #[test] fn monthly_without_a_date_has_no_due() {
        let p = parse("pay rent monthly high", &now());
        assert_eq!((p.title.as_str(), p.repeats, p.priority, p.due), ("pay rent", Some(Repeat::Monthly), Priority::High, None));
    }
    #[test] fn every_weekday_with_a_time() {
        let p = parse("stand up every weekday 9:30am", &now());
        assert_eq!(p.repeats, Some(Repeat::Weekdays)); assert_eq!(p.title, "stand up");
        let d = p.due.unwrap(); assert_eq!((d.hour(), d.minute_of()), (9, 30)); assert!(d > now());
    }
    #[test] fn tomorrow_and_in_hours() {
        assert_eq!(parse("call mum tomorrow", &now()).due.unwrap().day(), 6);
        let h = parse("check oven in 2 hours", &now()); assert_eq!(h.title, "check oven"); assert_eq!(h.due.unwrap().hour(), 11);
    }
    #[test] fn plain_text_stays_plain() { let p = parse("buy milk", &now()); assert_eq!((p.title.as_str(), p.due, p.repeats, p.priority), ("buy milk", None, None, Priority::Medium)); }
    #[test] fn explicit_dates() { let p = parse("renew passport 20 nov", &now()); assert_eq!(p.title, "renew passport"); assert_eq!(p.due.unwrap().day(), 20); }
    trait MinuteOf { fn minute_of(&self) -> u32; }
    impl MinuteOf for DateTime<FixedOffset> { fn minute_of(&self) -> u32 { chrono::Timelike::minute(self) } }
}
