//! Conservative input-age checks.
//!
//! Replay protection answers "was this packet already seen?". It does not
//! answer "is this input still current?". A previously unseen sequence number
//! can carry an old sample, especially after TCP buffering. This module turns
//! authenticated clock-offset bounds into an upper bound on sample age. When
//! freshness cannot be established, callers must remain neutral.

use crate::error::ProtocolError;
use crate::frame::{PingPayload, PongPayload};

const CLOCK_PROBE_TIMEOUT_US: u64 = 3_000_000;
const CLOCK_ESTIMATE_TTL_US: u64 = 5_000_000;
const CLOCK_DRIFT_PPM: u64 = 1_000;

/// One outstanding authenticated clock probe and one bounded estimate. This
/// conservative model assumes relative clock drift of at most 1000 ppm.
/// Only pass Pong frames after AEAD/replay checks; renew at least every 5 s.
#[derive(Debug, Default)]
pub struct ClockSync {
    next_id: u64,
    pending: Option<PingPayload>,
    estimate: Option<(ClockBounds, u64)>,
    last_now: Option<u64>,
}
impl ClockSync {
    pub fn new() -> Self {
        Self::default()
    }
    fn advance(&mut self, now_us: u64) -> Result<(), ProtocolError> {
        if self.last_now.is_some_and(|last| now_us < last) {
            self.pending = None;
            self.estimate = None;
            return Err(ProtocolError::ClockRegression);
        }
        self.last_now = Some(now_us);
        Ok(())
    }
    pub fn ping(&mut self, now_us: u64) -> Result<PingPayload, ProtocolError> {
        self.advance(now_us)?;
        if self
            .pending
            .is_some_and(|ping| now_us - ping.sent_time_us < CLOCK_PROBE_TIMEOUT_US)
        {
            return Err(ProtocolError::PairingState);
        }
        self.next_id = self
            .next_id
            .checked_add(1)
            .ok_or(ProtocolError::SequenceExhausted)?;
        let ping = PingPayload {
            ping_id: self.next_id,
            sent_time_us: now_us,
        };
        self.pending = Some(ping);
        Ok(ping)
    }
    pub fn accept_pong(
        &mut self,
        pong: &PongPayload,
        now_us: u64,
    ) -> Result<ClockBounds, ProtocolError> {
        self.advance(now_us)?;
        let ping = self
            .pending
            .ok_or(ProtocolError::ClockUncertaintyTooLarge)?;
        if pong.ping_id != ping.ping_id || pong.echo_time_us != ping.sent_time_us {
            return Err(ProtocolError::PairingRequestMismatch);
        }
        self.pending = None;
        let round_trip = now_us - ping.sent_time_us;
        let processing = pong
            .sent_time_us
            .checked_sub(pong.received_time_us)
            .ok_or(ProtocolError::ClockUncertaintyTooLarge)?;
        if round_trip >= CLOCK_PROBE_TIMEOUT_US || processing > round_trip {
            return Err(ProtocolError::ClockUncertaintyTooLarge);
        }
        // peer-local offset lies between t3-t4 and t2-t1. Nonnegative
        // one-way delays are sufficient; symmetric routing is not assumed.
        let low = i128::from(pong.sent_time_us) - i128::from(now_us);
        let high = i128::from(pong.received_time_us) - i128::from(ping.sent_time_us);
        let midpoint = (low + high).div_euclid(2);
        let offset =
            i64::try_from(midpoint).map_err(|_| ProtocolError::ClockUncertaintyTooLarge)?;
        let uncertainty = u64::try_from(high - midpoint)
            .map_err(|_| ProtocolError::ClockUncertaintyTooLarge)?
            + round_trip.div_ceil(1_000_000 / CLOCK_DRIFT_PPM);
        let bounds = ClockBounds::new(offset, uncertainty)?;
        self.estimate = Some((bounds, now_us));
        Ok(bounds)
    }
    pub fn bounds(&mut self, now_us: u64) -> Result<ClockBounds, ProtocolError> {
        self.advance(now_us)?;
        let (estimate, measured) = self
            .estimate
            .ok_or(ProtocolError::ClockUncertaintyTooLarge)?;
        let age = now_us - measured;
        if age >= CLOCK_ESTIMATE_TTL_US {
            self.estimate = None;
            return Err(ProtocolError::ClockUncertaintyTooLarge);
        }
        ClockBounds::new(
            estimate.offset_us,
            estimate.uncertainty_us + age.div_ceil(1_000_000 / CLOCK_DRIFT_PPM),
        )
    }
    /// Discard measured clocks at every endpoint/epoch transition.
    pub fn reset(&mut self) {
        self.pending = None;
        self.estimate = None;
    }
}

/// Beyond this measured uncertainty, freshness is considered unknowable.
///
/// This is an absolute ceiling. Even smaller uncertainties can make a sample
/// too old for the configured hold deadline.
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

    /// The earliest local-clock instant at which the sample could have occurred.
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

        let earliest = sample - offset - uncertainty;
        if earliest > now {
            return Err(ProtocolError::FutureSampleTime);
        }

        let capped = earliest.clamp(0, i128::from(u64::MAX));
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
    fn authenticated_probe_bounds_asymmetric_delay_and_grows_drift() {
        let mut sync = ClockSync::new();
        assert!(sync.bounds(1000).is_err());
        let ping = sync.ping(1000).unwrap();
        assert!(sync.ping(1001).is_err());
        let pong = PongPayload {
            ping_id: ping.ping_id,
            echo_time_us: 1000,
            received_time_us: 2200,
            sent_time_us: 2300,
        };
        let bounds = sync.accept_pong(&pong, 1500).unwrap();
        assert_eq!(bounds.offset_us, 1000);
        assert_eq!(bounds.uncertainty_us, 201);
        assert_eq!(sync.bounds(1_001_500).unwrap().uncertainty_us, 1201);
        assert!(sync.bounds(5_001_500).is_err());
    }

    #[test]
    fn unmatched_echo_duplicate_pong_invalid_times_and_regression_fail() {
        let mut sync = ClockSync::new();
        let ping = sync.ping(1000).unwrap();
        let mut pong = PongPayload {
            ping_id: ping.ping_id + 1,
            echo_time_us: 1000,
            received_time_us: 1000,
            sent_time_us: 1000,
        };
        assert!(sync.accept_pong(&pong, 1100).is_err());
        pong.ping_id = ping.ping_id;
        sync.accept_pong(&pong, 1200).unwrap();
        assert!(sync.accept_pong(&pong, 1200).is_err());
        assert_eq!(sync.bounds(1199), Err(ProtocolError::ClockRegression));
        assert!(sync.bounds(1200).is_err());
        let ping = sync.ping(2000).unwrap();
        pong.ping_id = ping.ping_id;
        pong.echo_time_us = ping.sent_time_us;
        pong.received_time_us = 1;
        pong.sent_time_us = 10_000;
        assert!(sync.accept_pong(&pong, 2100).is_err());
    }

    #[test]
    fn timed_out_probe_and_epoch_reset_cannot_establish_freshness() {
        let mut sync = ClockSync::new();
        let ping = sync.ping(0).unwrap();
        let pong = PongPayload {
            ping_id: ping.ping_id,
            echo_time_us: 0,
            received_time_us: 0,
            sent_time_us: 0,
        };
        assert!(sync.accept_pong(&pong, CLOCK_PROBE_TIMEOUT_US).is_err());
        sync.ping(CLOCK_PROBE_TIMEOUT_US).unwrap();
        sync.reset();
        assert!(sync.accept_pong(&pong, CLOCK_PROBE_TIMEOUT_US).is_err());
        assert!(sync.bounds(CLOCK_PROBE_TIMEOUT_US).is_err());
    }

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
        let bounds = ClockBounds::new(-1_000, 0).unwrap();
        assert_eq!(
            bounds.conservative_sample_time(5_000, 3_900).unwrap(),
            4_900
        );
        assert_eq!(bounds.age_upper_bound(5_000, 3_900).unwrap(), 100);

        let bounds = ClockBounds::new(1_000, 0).unwrap();
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
            8_800
        );
        assert_eq!(bounds.age_upper_bound(10_000, 8_900).unwrap(), 1_200);
        assert!(
            !ClockBounds::new(0, 500_000)
                .unwrap()
                .is_fresh(1_000_000, 600_000, 250_000)
                .unwrap()
        );
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
        let bounds = ClockBounds::new(i64::MIN, MAX_CLOCK_UNCERTAINTY_US).unwrap();
        assert_eq!(
            bounds.conservative_sample_time(u64::MAX, u64::MAX),
            Err(ProtocolError::FutureSampleTime)
        );

        let bounds = ClockBounds::new(i64::MAX, 0).unwrap();
        assert_eq!(bounds.conservative_sample_time(u64::MAX, 0).unwrap(), 0);
        assert_eq!(bounds.age_upper_bound(u64::MAX, 0).unwrap(), u64::MAX);
    }
}
