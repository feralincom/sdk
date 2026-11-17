use std::time::{SystemTime, UNIX_EPOCH};

/// Unix zamanından milisaniye; 1970 öncesi 0 sayılır.
pub(crate) fn epoch_millis(moment: SystemTime) -> u64 {
    moment.duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

/// UTC RFC3339, milisaniye hassasiyeti (ör. 2026-11-03T10:00:00.123Z). Tarih kütüphanesi eklememek için takvim hesabı burada.
pub(crate) fn format_time(moment: SystemTime) -> String {
    let millis = epoch_millis(moment);
    let seconds = millis / 1000;
    let (year, month, day) = civil_from_days((seconds / 86_400) as i64);
    let rest = seconds % 86_400;
    format!("{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}.{:03}Z", rest / 3600, rest % 3600 / 60, rest % 60, millis % 1000)
}

/// Gün sayısından proleptik Gregoryen takvim tarihi (Howard Hinnant'ın `civil_from_days` algoritması).
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + if month <= 2 { 1 } else { 0 };
    (year, month as u32, day)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    fn at(millis: u64) -> SystemTime {
        UNIX_EPOCH + Duration::from_millis(millis)
    }

    #[test]
    fn formats_known_moments() {
        assert_eq!(format_time(at(0)), "1970-01-01T00:00:00.000Z");
        assert_eq!(format_time(at(1_793_703_600_123)), "2026-11-03T11:00:00.123Z");
        assert_eq!(format_time(at(1_767_323_045_000)), "2026-01-02T03:04:05.000Z");
    }

    #[test]
    fn handles_leap_day_and_year_end() {
        assert_eq!(format_time(at(1_709_164_800_000)), "2024-02-29T00:00:00.000Z");
        assert_eq!(format_time(at(1_735_689_599_999)), "2024-12-31T23:59:59.999Z");
    }

    #[test]
    fn truncates_sub_millisecond() {
        let moment = UNIX_EPOCH + Duration::from_nanos(1_500_999_999);
        assert_eq!(format_time(moment), "1970-01-01T00:00:01.500Z");
    }
}
