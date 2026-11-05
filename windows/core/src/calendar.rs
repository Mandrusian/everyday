//! Calendar without an operating-system calendar API: read any public or secret iCalendar (.ics) link, such as the one Google Calendar,
//! Outlook or iCloud can publish. Handles all-day events, UTC and floating times, and simple repeats (daily, weekly, monthly, yearly with INTERVAL/COUNT/UNTIL).
use chrono::{DateTime, Datelike, Days, Duration, Months, NaiveDate, NaiveDateTime, TimeZone, Utc};

#[derive(Debug, Clone, PartialEq)]
pub struct Event { pub title: String, pub start: DateTime<Utc>, pub end: Option<DateTime<Utc>>, pub all_day: bool, pub location: String }

fn unfold(s: &str) -> Vec<String> {
    let mut out: Vec<String> = vec![];
    for line in s.replace("\r\n", "\n").split('\n') { if (line.starts_with(' ') || line.starts_with('\t')) && !out.is_empty() { out.last_mut().unwrap().push_str(&line[1..]); } else { out.push(line.to_string()); } }
    out
}
fn unescape(s: &str) -> String { s.replace("\\n", " ").replace("\\N", " ").replace("\\,", ",").replace("\\;", ";").replace("\\\\", "\\") }

fn parse_dt(value: &str, params: &str, offset_secs: i32) -> Option<(DateTime<Utc>, bool)> {
    let v = value.trim();
    if params.contains("VALUE=DATE") || (v.len() == 8 && !v.contains('T')) {
        let d = NaiveDate::parse_from_str(v, "%Y%m%d").ok()?; return Some((Utc.from_utc_datetime(&d.and_hms_opt(0, 0, 0)?), true));
    }
    if let Some(z) = v.strip_suffix('Z') { let n = NaiveDateTime::parse_from_str(z, "%Y%m%dT%H%M%S").ok()?; return Some((Utc.from_utc_datetime(&n), false)); }
    let n = NaiveDateTime::parse_from_str(v, "%Y%m%dT%H%M%S").ok()?;      // floating or TZID: treated in the reader's local offset
    Some((Utc.from_utc_datetime(&(n - Duration::seconds(offset_secs as i64))), false))
}

struct Rule { freq: String, interval: u32, count: Option<u32>, until: Option<DateTime<Utc>> }
fn parse_rrule(v: &str, offset: i32) -> Option<Rule> {
    let mut r = Rule { freq: String::new(), interval: 1, count: None, until: None };
    for kv in v.split(';') { let (k, val) = kv.split_once('=')?; match k { "FREQ" => r.freq = val.into(), "INTERVAL" => r.interval = val.parse().unwrap_or(1).max(1), "COUNT" => r.count = val.parse().ok(), "UNTIL" => r.until = parse_dt(val, "", offset).map(|x| x.0), _ => {} } }
    if r.freq.is_empty() { None } else { Some(r) }
}
fn step(d: DateTime<Utc>, r: &Rule) -> Option<DateTime<Utc>> {
    match r.freq.as_str() { "DAILY" => d.checked_add_days(Days::new(r.interval as u64)), "WEEKLY" => d.checked_add_days(Days::new(7 * r.interval as u64)), "MONTHLY" => d.checked_add_months(Months::new(r.interval)), "YEARLY" => d.checked_add_months(Months::new(12 * r.interval)), _ => None }
}

/// Events (with repeats expanded) that start within [from, to]. `offset_secs` is the reader's UTC offset for floating times.
pub fn parse_ics(text: &str, from: DateTime<Utc>, to: DateTime<Utc>, offset_secs: i32) -> Vec<Event> {
    let mut out = vec![]; let mut cur: Option<(String, Option<(DateTime<Utc>, bool)>, Option<DateTime<Utc>>, String, Option<Rule>)> = None; let mut cancelled = false;
    for line in unfold(text) {
        if line == "BEGIN:VEVENT" { cur = Some((String::new(), None, None, String::new(), None)); cancelled = false; continue; }
        if line == "END:VEVENT" {
            if let Some((title, Some((start, all_day)), end, loc, rule)) = cur.take() { if !cancelled {
                let dur = end.map(|e| e - start);
                let mut s = start; let mut n = 0u32;
                loop {
                    if s > to { break; }
                    if let Some(r) = &rule { if r.count.map_or(false, |c| n >= c) || r.until.map_or(false, |u| s > u) { break; } }
                    if s >= from || dur.map_or(false, |d| s + d >= from) { out.push(Event { title: title.clone(), start: s, end: dur.map(|d| s + d), all_day, location: loc.clone() }); }
                    n += 1; match &rule { Some(r) => match step(s, r) { Some(x) => s = x, None => break }, None => break }
                    if n > 2000 { break; }
                }
            } }
            continue;
        }
        let Some(c) = cur.as_mut() else { continue };
        let (name_params, value) = match line.split_once(':') { Some(x) => x, None => continue };
        let (name, params) = name_params.split_once(';').unwrap_or((name_params, ""));
        match name { "SUMMARY" => c.0 = unescape(value), "DTSTART" => c.1 = parse_dt(value, params, offset_secs), "DTEND" => c.2 = parse_dt(value, params, offset_secs).map(|x| x.0), "LOCATION" => c.3 = unescape(value), "RRULE" => c.4 = parse_rrule(value, offset_secs), "STATUS" if value.trim() == "CANCELLED" => cancelled = true, _ => {} }
    }
    out.sort_by_key(|e| e.start); out
}

/// "Today: 9:30 Standup; 14:00 Dentist". Empty when nothing is on.
pub fn summary_line(events: &[Event], now: DateTime<Utc>, offset_secs: i32) -> String {
    let local = |d: DateTime<Utc>| d + Duration::seconds(offset_secs as i64);
    let today = local(now).date_naive();
    events.iter().filter(|e| local(e.start).date_naive() == today).map(|e| if e.all_day { format!("All day {}", e.title) } else { format!("{} {}", local(e.start).format("%H:%M"), e.title) }).collect::<Vec<_>>().join("; ")
}
pub fn _year(d: DateTime<Utc>) -> i32 { d.year() }

#[cfg(test)]
mod tests {
    use super::*;
    fn t(y: i32, m: u32, d: u32, h: u32) -> DateTime<Utc> { Utc.with_ymd_and_hms(y, m, d, h, 0, 0).unwrap() }
    const ICS: &str = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:Standup\r\nDTSTART:20261105T233000Z\r\nDTEND:20261106T000000Z\r\nRRULE:FREQ=DAILY;COUNT=3\r\nEND:VEVENT\r\nBEGIN:VEVENT\r\nSUMMARY:Dentist\\, Cairns\r\nDTSTART;TZID=Australia/Brisbane:20261105T140000\r\nLOCATION:12 Abbott St\r\nEND:VEVENT\r\nBEGIN:VEVENT\r\nSUMMARY:Public holiday\r\nDTSTART;VALUE=DATE:20261105\r\nEND:VEVENT\r\nBEGIN:VEVENT\r\nSUMMARY:Cancelled thing\r\nSTATUS:CANCELLED\r\nDTSTART:20261105T100000Z\r\nEND:VEVENT\r\nBEGIN:VEVENT\r\nSUMMARY:Long\r\n title folded\r\nDTSTART:20270101T000000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
    #[test] fn events_with_times_all_day_escapes_and_cancellations() {
        let ev = parse_ics(ICS, t(2026, 11, 5, 0), t(2026, 11, 6, 23), 10 * 3600);
        let titles: Vec<&str> = ev.iter().map(|e| e.title.as_str()).collect();
        assert!(titles.contains(&"Dentist, Cairns") && titles.contains(&"Public holiday") && !titles.contains(&"Cancelled thing"));
        let d = ev.iter().find(|e| e.title.starts_with("Dentist")).unwrap(); assert_eq!(d.start, t(2026, 11, 5, 4)); assert_eq!(d.location, "12 Abbott St");   // 14:00 at +10 is 04:00 UTC
        assert!(ev.iter().find(|e| e.title == "Public holiday").unwrap().all_day);
    }
    #[test] fn daily_repeats_expand_and_stop_at_count() {
        let ev = parse_ics(ICS, t(2026, 11, 5, 0), t(2026, 11, 30, 0), 0); let s: Vec<_> = ev.iter().filter(|e| e.title == "Standup").collect();
        assert_eq!(s.len(), 3); assert_eq!(s[1].start, t(2026, 11, 6, 23) + Duration::minutes(30));
    }
    #[test] fn folded_lines_are_joined_and_far_events_are_excluded() {
        assert!(parse_ics(ICS, t(2026, 11, 5, 0), t(2026, 11, 6, 0), 0).iter().all(|e| e.title != "Longtitle folded"));
        assert!(parse_ics(ICS, t(2026, 12, 31, 0), t(2027, 1, 2, 0), 0).iter().any(|e| e.title == "Longtitle folded"));
    }
    #[test] fn the_summary_line_lists_today_in_local_time() {
        let ev = parse_ics(ICS, t(2026, 11, 5, 0), t(2026, 11, 5, 23), 10 * 3600);
        let s = summary_line(&ev, t(2026, 11, 5, 3), 10 * 3600); assert!(s.contains("14:00 Dentist, Cairns") && s.contains("All day Public holiday"), "{s}");
    }
    #[test] fn garbage_is_ignored() { assert!(parse_ics("not a calendar", t(2026, 1, 1, 0), t(2027, 1, 1, 0), 0).is_empty()); }
}
