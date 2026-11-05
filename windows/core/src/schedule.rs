//! When the morning briefing is due: once per day, from the chosen hour, even if the app opens later that day.
use chrono::{DateTime, Datelike, TimeZone, Timelike};

pub fn day_key<Tz: TimeZone>(d: &DateTime<Tz>) -> String { format!("{}-{}-{}", d.year(), d.month(), d.day()) }

pub fn should_send<Tz: TimeZone>(now: &DateTime<Tz>, hour: u32, last_sent: &str) -> bool {
    now.hour() >= hour && last_sent != day_key(now)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;
    fn d(day: u32, hour: u32) -> DateTime<Utc> { Utc.with_ymd_and_hms(2026, 11, day, hour, 5, 0).unwrap() }
    #[test] fn waits_for_the_chosen_hour() { assert!(!should_send(&d(5, 6), 7, "")); assert!(should_send(&d(5, 7), 7, "")); }
    #[test] fn sends_once_a_day_and_again_the_next_day() {
        assert!(!should_send(&d(5, 9), 7, &day_key(&d(5, 7))));
        assert!(should_send(&d(6, 7), 7, &day_key(&d(5, 7))));
    }
}
