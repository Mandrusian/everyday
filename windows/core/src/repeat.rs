//! Repeating tasks: when a task with a repeat rule is completed, the next one is scheduled in the future.
use chrono::{DateTime, Datelike, Days, Months, TimeZone, Weekday};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Repeat { Daily, Weekdays, Weekly, Monthly, Yearly }

impl Repeat {
    pub fn title(self) -> &'static str {
        match self { Repeat::Daily => "Every day", Repeat::Weekdays => "Every weekday", Repeat::Weekly => "Every week", Repeat::Monthly => "Every month", Repeat::Yearly => "Every year" }
    }

    fn step<Tz: TimeZone>(self, x: &DateTime<Tz>) -> DateTime<Tz> {
        let add_days = |d: &DateTime<Tz>, n: u64| d.clone().checked_add_days(Days::new(n)).unwrap_or_else(|| d.clone());
        match self {
            Repeat::Daily => add_days(x, 1),
            Repeat::Weekly => add_days(x, 7),
            Repeat::Monthly => x.clone().checked_add_months(Months::new(1)).unwrap_or_else(|| x.clone()),
            Repeat::Yearly => x.clone().checked_add_months(Months::new(12)).unwrap_or_else(|| x.clone()),
            Repeat::Weekdays => { let mut n = add_days(x, 1); while matches!(n.weekday(), Weekday::Sat | Weekday::Sun) { n = add_days(&n, 1); } n }
        }
    }

    /// The next due date after `due` (or after `now` when there is none), always in the future.
    pub fn next<Tz: TimeZone>(self, due: Option<&DateTime<Tz>>, now: &DateTime<Tz>) -> DateTime<Tz> {
        let mut d = self.step(due.unwrap_or(now));
        let mut guard = 0;
        while d <= *now && guard < 800 { d = self.step(&d); guard += 1; }
        d
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{Timelike, Utc};
    fn at(m: u32, d: u32, h: u32) -> DateTime<Utc> { Utc.with_ymd_and_hms(2026, m, d, h, 0, 0).unwrap() }
    #[test] fn weekdays_skip_the_weekend() { assert_eq!(Repeat::Weekdays.next(Some(&at(11, 6, 17)), &at(11, 5, 9)), at(11, 9, 17)); }
    #[test] fn an_old_due_date_catches_up() { assert!(Repeat::Weekly.next(Some(&at(9, 4, 17)), &at(11, 5, 9)) > at(11, 5, 9)); }
    #[test] fn monthly_keeps_the_time_of_day() { assert_eq!(Repeat::Monthly.next(Some(&at(11, 6, 17)), &at(11, 5, 9)).hour(), 17); }
    #[test] fn without_a_due_date_it_counts_from_now() { assert_eq!(Repeat::Daily.next(None, &at(11, 5, 9)), at(11, 6, 9)); }
}
