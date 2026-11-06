//! Conservative input-age checks.
//!
//! Replay protection answers "was this packet already seen?". It does not
//! answer "is this input still current?". A previously unseen sequence number
//! can carry an old sample, especially after TCP buffering. This module turns
//! authenticated clock-offset bounds into an upper bound on sample age. When
//! freshness cannot be established, callers must remain neutral.

use crate::error::ProtocolError;

/// Beyond this measured uncertainty, freshness is considered unknowable.
///
/// The value is deliberately much larger than the 250 ms input watchdog so a
/// clock-sync failure cannot accidentally pass freshness checks.
pub const MAX_CLOCK_UNCERTAINTY_US: u64 = 500_000;

/// A conservative interval around the peer's monotonic clock.
///
/// `offset_us` is `peer_clock - local_clock` at the midpoint of the estimate.
/// `uncertainty_us` is the half-width of the confidence interval, including
/// measured drift for the age of the estimate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ClockBounds {
    offset_us: i64,
    uncertainty_us: u64,
}

impl ClockBounds {
    /// Creates bounds, rejecting uncertainty that is too large to be useful.
    pub fn new(offset_us: i64, uncertainty_us: u64) -> Result<Self, ProtocolError> {
        if uncertainty_us > MAX_CLOCK_UNCERTAINTY_US {
            return Err(ProtocolError::ClockUncertaintyTooLarge);
        }
        Ok(Self {
            offset_us,
            uncertainty_us,
        })
    }

    /// The newest local-clock instant at which the sample could have occurred.
    ///
    /// Returns an error when even the earliest possible moment is in the
    /// future beyond the measured bounds. The result is capped at `now_us`,
    /// because an actual sample cannot be later than the local present.
    pub fn conservative_sample_time(
        &self,
        now_us: u64,
        sample_time_us: u64,
    ) -> Result<u64, ProtocolError> {
        let sample = i128::from(sample_time_us);
        let offset = i128::from(self.offset_us);
        let uncertainty = i128::from(self.uncertainty_us);
        let now = i128::from(now_us);

        if sample + offset - uncertainty > now {
            return Err(ProtocolError::FutureSampleTime);
        }

        let upper = sample + offset + uncertainty;
        let capped = upper.clamp(0, i128::from(u64::MAX));
        Ok((capped as u64).min(now_us))
    }

    /// Upper bound on how long ago the sample was taken.
    ///
    /// A result of `0` means the sample might be current; it does not prove the
    /// sample is fresh enough for the watchdog.
    pub fn age_upper_bound(&self, now_us: u64, sample_time_us: u64) -> Result<u64, ProtocolError> {
        let conservative = self.conservative_sample_time(now_us, sample_time_us)?;
        Ok(now_us.saturating_sub(conservative))
    }

    /// Returns whether the sample is at most `maximum_age_us` old under the
    /// conservative bounds.
    pub fn is_fresh(
        &self,
        now_us: u64,
        sample_time_us: u64,
        maximum_age_us: u64,
    ) -> Result<bool, ProtocolError> {
        Ok(self.age_upper_bound(now_us, sample_time_us)? <= maximum_age_us)
    }

    /// Measured half-width of the offset interval.
    pub const fn uncertainty_us(&self) -> u64 {
        self.uncertainty_us
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exact_clock_measures_direct_age() {
        let bounds = ClockBounds::new(0, 0).unwrap();
        assert_eq!(
            bounds.conservative_sample_time(10_000, 9_000).unwrap(),
            9_000
        );
        assert_eq!(bounds.age_upper_bound(10_000, 9_000).unwrap(), 1_000);
        assert!(bounds.is_fresh(10_000, 9_000, 1_000).unwrap());
        assert!(!bounds.is_fresh(10_000, 9_000, 999).unwrap());
    }

    #[test]
    fn offset_moves_the_estimate() {
        let bounds = ClockBounds::new(1_000, 0).unwrap();
        assert_eq!(
            bounds.conservative_sample_time(5_000, 3_900).unwrap(),
            4_900
        );
        assert_eq!(bounds.age_upper_bound(5_000, 3_900).unwrap(), 100);

        let bounds = ClockBounds::new(-1_000, 0).unwrap();
        assert_eq!(
            bounds.conservative_sample_time(5_000, 6_000).unwrap(),
            5_000
        );
        assert_eq!(bounds.age_upper_bound(5_000, 6_000).unwrap(), 0);
    }

    #[test]
    fn uncertainty_makes_the_age_upper_bound_larger() {
        let bounds = ClockBounds::new(0, 100).unwrap();
        assert_eq!(
            bounds.conservative_sample_time(10_000, 8_900).unwrap(),
            9_000
        );
        assert_eq!(bounds.age_upper_bound(10_000, 8_900).unwrap(), 1_000);
    }

    #[test]
    fn future_samples_beyond_bounds_are_rejected() {
        let bounds = ClockBounds::new(0, 100).unwrap();
        assert_eq!(
            bounds.age_upper_bound(10_000, 10_101),
            Err(ProtocolError::FutureSampleTime)
        );
        assert!(bounds.age_upper_bound(10_000, 10_100).is_ok());
    }

    #[test]
    fn excessive_uncertainty_is_rejected() {
        assert_eq!(
            ClockBounds::new(0, MAX_CLOCK_UNCERTAINTY_US + 1),
            Err(ProtocolError::ClockUncertaintyTooLarge)
        );
        assert!(ClockBounds::new(0, MAX_CLOCK_UNCERTAINTY_US).is_ok());
    }

    #[test]
    fn extreme_values_do_not_overflow() {
        let bounds = ClockBounds::new(i64::MAX, MAX_CLOCK_UNCERTAINTY_US).unwrap();
        assert_eq!(
            bounds.conservative_sample_time(u64::MAX, u64::MAX),
            Err(ProtocolError::FutureSampleTime)
        );

        let bounds = ClockBounds::new(i64::MIN, 0).unwrap();
        assert_eq!(bounds.conservative_sample_time(u64::MAX, 0).unwrap(), 0);
        assert_eq!(bounds.age_upper_bound(u64::MAX, 0).unwrap(), u64::MAX);
    }
}
