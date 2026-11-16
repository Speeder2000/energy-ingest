// SPDX-License-Identifier: MIT

//! Optional hourly presentation of resolved interval streams.
//!
//! Energy intervals are additive, so summing the sub-hour readings of one
//! complete UTC hour preserves the total exactly. An hour is emitted only
//! when its readings cover it without gaps; a partial hour is omitted, never
//! estimated. Intervals of an hour or longer pass through unchanged.
//! Canonical storage, validation and fingerprints remain at the source
//! resolution.

use crate::SelectedInterval;
use chrono::Timelike;
use sqlx::types::chrono::NaiveDateTime;

const HOUR_SECONDS: u32 = 3_600;

/// The interval resolution an API response presents.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash)]
pub enum Resolution {
    /// Intervals exactly as the utility supplied them.
    #[default]
    Native,
    /// Sub-hour intervals summed into complete UTC hours.
    Hour,
}

impl Resolution {
    /// Machine-readable identifier shared by all presentation surfaces.
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Native => "native",
            Self::Hour => "hour",
        }
    }

    /// Parses the identifier returned by [`Resolution::as_str`].
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "native" => Some(Self::Native),
            "hour" => Some(Self::Hour),
            _ => None,
        }
    }

    /// Presents resolved intervals at this resolution.
    pub fn apply(
        self,
        intervals: Vec<SelectedInterval>,
    ) -> Vec<SelectedInterval> {
        match self {
            Self::Native => intervals,
            Self::Hour => aggregate_hourly(intervals),
        }
    }
}

fn hour_of(start: NaiveDateTime) -> NaiveDateTime {
    start
        .with_minute(0)
        .and_then(|t| t.with_second(0))
        .and_then(|t| t.with_nanosecond(0))
        .expect("valid time components")
}

/// Sums sub-hour intervals into complete UTC hours.
///
/// Returns intervals ordered by start. Hours that are not fully covered by
/// contiguous readings of one measurement type, or whose sum would
/// overflow, are omitted.
pub fn aggregate_hourly(
    mut intervals: Vec<SelectedInterval>,
) -> Vec<SelectedInterval> {
    intervals.sort_by_key(|i| (i.start, i.duration_seconds));
    let mut result = Vec::with_capacity(intervals.len() / 4 + 1);
    let mut index = 0;
    while index < intervals.len() {
        let first = &intervals[index];
        if first.duration_seconds >= HOUR_SECONDS {
            result.push(first.clone());
            index += 1;
            continue;
        }
        let hour = hour_of(first.start);
        let mut end = index;
        while end < intervals.len()
            && intervals[end].duration_seconds < HOUR_SECONDS
            && hour_of(intervals[end].start) == hour
        {
            end += 1;
        }
        if let Some(sum) = complete_hour(hour, &intervals[index..end]) {
            result.push(sum);
        }
        index = end;
    }
    result
}

fn complete_hour(
    hour: NaiveDateTime,
    group: &[SelectedInterval],
) -> Option<SelectedInterval> {
    let first = group.first()?;
    let mut cursor = hour;
    let mut total: i64 = 0;
    let mut revision = 0;
    for item in group {
        if item.start != cursor
            || item.power_of_ten_multiplier != first.power_of_ten_multiplier
            || item.unit_of_measure != first.unit_of_measure
        {
            return None;
        }
        cursor = cursor.checked_add_signed(chrono::Duration::seconds(
            i64::from(item.duration_seconds),
        ))?;
        total = total.checked_add(item.raw_value)?;
        revision = revision.max(item.accepted_revision_id);
    }
    if cursor != hour + chrono::Duration::seconds(i64::from(HOUR_SECONDS)) {
        return None;
    }
    Some(SelectedInterval {
        start: hour,
        duration_seconds: HOUR_SECONDS,
        raw_value: total,
        meter_reading_id: first.meter_reading_id,
        // The newest contributing revision identifies the hourly value.
        accepted_revision_id: revision,
        power_of_ten_multiplier: first.power_of_ten_multiplier,
        unit_of_measure: first.unit_of_measure,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(minute_offset: i64, duration: u32, value: i64) -> SelectedInterval {
        let base = NaiveDateTime::parse_from_str(
            "2026-07-01T00:00:00",
            "%Y-%m-%dT%H:%M:%S",
        )
        .unwrap();
        SelectedInterval {
            start: base + chrono::Duration::minutes(minute_offset),
            duration_seconds: duration,
            raw_value: value,
            meter_reading_id: 1,
            accepted_revision_id: 100 + minute_offset as u64,
            power_of_ten_multiplier: 0,
            unit_of_measure: 72,
        }
    }

    #[test]
    fn quarter_hours_sum_into_complete_hours() {
        let data: Vec<_> = (0..8).map(|q| at(q * 15, 900, 10 + q)).collect();
        let hours = aggregate_hourly(data);
        assert_eq!(hours.len(), 2);
        assert_eq!(hours[0].start, at(0, 900, 0).start);
        assert_eq!(hours[0].duration_seconds, 3600);
        assert_eq!(hours[0].raw_value, 10 + 11 + 12 + 13);
        assert_eq!(hours[1].raw_value, 14 + 15 + 16 + 17);
        assert_eq!(hours[0].accepted_revision_id, 145);
    }

    #[test]
    fn incomplete_hour_is_omitted_not_estimated() {
        let data = vec![at(0, 900, 1), at(15, 900, 1), at(45, 900, 1)];
        assert!(aggregate_hourly(data).is_empty());
        let data = vec![at(0, 900, 1), at(15, 900, 1), at(30, 900, 1)];
        assert!(aggregate_hourly(data).is_empty());
    }

    #[test]
    fn hourly_and_daily_intervals_pass_through() {
        let data = vec![at(0, 3600, 5), at(60, 86_400, 7)];
        assert_eq!(aggregate_hourly(data.clone()), data);
    }

    #[test]
    fn mixed_measurement_types_are_not_summed() {
        let mut odd = at(45, 900, 1);
        odd.power_of_ten_multiplier = -3;
        let data = vec![at(0, 900, 1), at(15, 900, 1), at(30, 900, 1), odd];
        assert!(aggregate_hourly(data).is_empty());
    }

    #[test]
    fn totals_are_preserved_for_complete_data() {
        let data: Vec<_> = (0..96).map(|q| at(q * 15, 900, q * 3)).collect();
        let total: i64 = data.iter().map(|i| i.raw_value).sum();
        let hours = aggregate_hourly(data);
        assert_eq!(hours.len(), 24);
        assert_eq!(hours.iter().map(|i| i.raw_value).sum::<i64>(), total);
    }

    #[test]
    fn resolution_identifiers_round_trip() {
        for r in [Resolution::Native, Resolution::Hour] {
            assert_eq!(Resolution::parse(r.as_str()), Some(r));
        }
        assert_eq!(Resolution::parse("15m"), None);
        assert_eq!(Resolution::default(), Resolution::Native);
    }
}
