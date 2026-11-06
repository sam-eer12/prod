//! Input watchdog: hold, neutralize, reconnect, and expire state machine.
//!
//! Freshness is anchored to the conservative sample time, not to packet
//! arrival. A late packet therefore gets only the remainder of its hold
//! deadline. Ping, rumble, acknowledgment, and replay traffic can never extend
//! this timer because those paths do not call [`Watchdog::on_fresh_input`].

use crate::error::ProtocolError;

/// Default hold time after the newest fresh sample.
pub const DEFAULT_NEUTRAL_MS: u16 = 250;
/// Minimum configurable hold time.
pub const MIN_NEUTRAL_MS: u16 = 100;
/// Maximum configurable hold time.
pub const MAX_NEUTRAL_MS: u16 = 250;
/// Time after the last fresh sample at which the UI reports `RECONNECTING`.
pub const RECONNECT_AFTER_MS: u64 = 5_000;
/// Time after the last fresh sample at which the session is destroyed.
pub const EXPIRE_AFTER_MS: u64 = 30_000;

/// Current watchdog phase.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WatchdogPhase {
    /// No session.
    Idle,
    /// Session is live; output may be enabled only after fresh input.
    Active,
    /// Output is latched off; recovery must rearm explicitly.
    Neutral,
    /// Neutral for at least five seconds; recovery is still possible.
    Reconnecting,
    /// Recovery deadline elapsed; a new pairing is required.
    Expired,
}

/// One-shot transition produced by a tick.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WatchdogEvent {
    None,
    Neutralized,
    Reconnecting,
    Expired,
    Rearmed,
}

/// Result of a watchdog tick.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WatchdogTick {
    pub event: WatchdogEvent,
    pub phase: WatchdogPhase,
    pub output_allowed: bool,
}

/// Session input watchdog.
#[derive(Debug, Clone)]
pub struct Watchdog {
    neutral_ms: u16,
    phase: WatchdogPhase,
    reference_us: u64,
    hold_reference_us: u64,
    output_allowed: bool,
}

impl Watchdog {
    /// Creates an idle watchdog with a validated hold time.
    pub fn new(neutral_ms: u16) -> Result<Self, ProtocolError> {
        if !(MIN_NEUTRAL_MS..=MAX_NEUTRAL_MS).contains(&neutral_ms) {
            return Err(ProtocolError::ValueOutOfRange {
                field: "watchdog.neutral_ms",
            });
        }
        Ok(Self {
            neutral_ms,
            phase: WatchdogPhase::Idle,
            reference_us: 0,
            hold_reference_us: 0,
            output_allowed: false,
        })
    }

    /// Starts a session in the neutral, not-yet-armed state.
    pub fn activate(&mut self, now_us: u64) {
        self.phase = WatchdogPhase::Active;
        self.reference_us = now_us;
        self.hold_reference_us = now_us;
        self.output_allowed = false;
    }

    /// Records a fresh authenticated State sample.
    ///
    /// `conservative_sample_us` is the sample time converted to the local
    /// monotonic clock with the conservative clock bounds. Returns whether
    /// output may be enabled. Input while latched off does not rearm the
    /// watchdog.
    pub fn on_fresh_input(
        &mut self,
        conservative_sample_us: u64,
        now_us: u64,
    ) -> Result<bool, ProtocolError> {
        self.tick(now_us);
        if self.phase != WatchdogPhase::Active {
            return Err(ProtocolError::WatchdogNotRearmable);
        }
        if conservative_sample_us < self.reference_us {
            return Err(ProtocolError::StaleSampleTime);
        }
        if conservative_sample_us > now_us {
            return Err(ProtocolError::FutureSampleTime);
        }

        let neutral_at = conservative_sample_us.saturating_add(self.neutral_us());
        if now_us >= neutral_at {
            self.phase = WatchdogPhase::Neutral;
            self.output_allowed = false;
            return Ok(false);
        }

        self.reference_us = conservative_sample_us;
        self.hold_reference_us = conservative_sample_us;
        self.output_allowed = true;
        Ok(true)
    }

    /// Advances deadlines and returns the highest transition reached.
    pub fn tick(&mut self, now_us: u64) -> WatchdogTick {
        let neutral_at = self.hold_reference_us.saturating_add(self.neutral_us());
        let reconnect_at = self.reference_us.saturating_add(RECONNECT_AFTER_MS * 1_000);
        let expire_at = self.reference_us.saturating_add(EXPIRE_AFTER_MS * 1_000);

        let event = if self.phase == WatchdogPhase::Expired || self.phase == WatchdogPhase::Idle {
            WatchdogEvent::None
        } else if now_us >= expire_at {
            self.phase = WatchdogPhase::Expired;
            self.output_allowed = false;
            WatchdogEvent::Expired
        } else if now_us >= reconnect_at
            && !(self.phase == WatchdogPhase::Active && !self.output_allowed && now_us < neutral_at)
        {
            if self.phase == WatchdogPhase::Reconnecting {
                WatchdogEvent::None
            } else {
                self.phase = WatchdogPhase::Reconnecting;
                self.output_allowed = false;
                WatchdogEvent::Reconnecting
            }
        } else if now_us >= neutral_at {
            if self.phase == WatchdogPhase::Active {
                self.phase = WatchdogPhase::Neutral;
                self.output_allowed = false;
                WatchdogEvent::Neutralized
            } else {
                WatchdogEvent::None
            }
        } else {
            WatchdogEvent::None
        };

        WatchdogTick {
            event,
            phase: self.phase,
            output_allowed: self.output_allowed,
        }
    }

    /// Neutralizes immediately without extending the resume deadline.
    pub fn neutralize_now(&mut self) {
        if matches!(
            self.phase,
            WatchdogPhase::Active | WatchdogPhase::Neutral | WatchdogPhase::Reconnecting
        ) {
            self.phase = WatchdogPhase::Neutral;
        }
        self.output_allowed = false;
    }

    /// Ends the session immediately; a new pairing is required.
    pub fn expire_now(&mut self) {
        self.phase = WatchdogPhase::Expired;
        self.output_allowed = false;
    }

    /// Rearms from a confirmed fresh epoch and neutral baseline.
    ///
    /// The next fresh State sample starts output. An expired watchdog cannot be
    /// rearmed; the caller must run the six-character pairing flow again.
    pub fn rearm(&mut self, now_us: u64) -> Result<(), ProtocolError> {
        self.tick(now_us);
        if !matches!(
            self.phase,
            WatchdogPhase::Active | WatchdogPhase::Neutral | WatchdogPhase::Reconnecting
        ) {
            return Err(ProtocolError::WatchdogNotRearmable);
        }

        self.phase = WatchdogPhase::Active;
        // Give the new epoch a bounded window to send State, while preserving
        // the last actual input's reconnect/expiry deadlines.
        self.hold_reference_us = now_us;
        self.output_allowed = false;
        Ok(())
    }

    /// Current phase.
    pub const fn phase(&self) -> WatchdogPhase {
        self.phase
    }

    /// Whether gamepad output is currently enabled.
    pub const fn output_allowed(&self) -> bool {
        self.output_allowed
    }

    /// Configured hold time.
    pub const fn neutral_ms(&self) -> u16 {
        self.neutral_ms
    }

    /// Last accepted conservative sample or activation time.
    pub const fn reference_us(&self) -> u64 {
        self.reference_us
    }

    const fn neutral_us(&self) -> u64 {
        self.neutral_ms as u64 * 1_000
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ms(value: u64) -> u64 {
        value * 1_000
    }

    #[test]
    fn configuration_is_bounded() {
        assert!(Watchdog::new(MIN_NEUTRAL_MS).is_ok());
        assert!(Watchdog::new(MAX_NEUTRAL_MS).is_ok());
        assert!(Watchdog::new(MIN_NEUTRAL_MS - 1).is_err());
        assert!(Watchdog::new(MAX_NEUTRAL_MS + 1).is_err());
    }

    #[test]
    fn no_input_neutralizes_reconnects_and_expires() {
        let mut watchdog = Watchdog::new(DEFAULT_NEUTRAL_MS).unwrap();
        watchdog.activate(0);

        let tick = watchdog.tick(ms(249));
        assert_eq!(tick.event, WatchdogEvent::None);
        assert_eq!(tick.phase, WatchdogPhase::Active);

        let tick = watchdog.tick(ms(250));
        assert_eq!(tick.event, WatchdogEvent::Neutralized);
        assert_eq!(tick.phase, WatchdogPhase::Neutral);
        assert!(!tick.output_allowed);

        let tick = watchdog.tick(ms(5_000));
        assert_eq!(tick.event, WatchdogEvent::Reconnecting);
        assert_eq!(tick.phase, WatchdogPhase::Reconnecting);

        let tick = watchdog.tick(ms(30_000));
        assert_eq!(tick.event, WatchdogEvent::Expired);
        assert_eq!(tick.phase, WatchdogPhase::Expired);
        assert!(!tick.output_allowed);
    }

    #[test]
    fn fresh_input_extends_the_hold_deadline() {
        let mut watchdog = Watchdog::new(DEFAULT_NEUTRAL_MS).unwrap();
        watchdog.activate(0);

        assert!(watchdog.on_fresh_input(ms(100), ms(100)).unwrap());
        assert_eq!(watchdog.tick(ms(349)).phase, WatchdogPhase::Active);
        assert_eq!(watchdog.tick(ms(350)).phase, WatchdogPhase::Neutral);
    }

    #[test]
    fn late_sample_gets_only_the_remainder_of_the_deadline() {
        let mut watchdog = Watchdog::new(DEFAULT_NEUTRAL_MS).unwrap();
        watchdog.activate(ms(800));

        // The sample was taken 200 ms ago, so only 50 ms of hold remains.
        assert!(watchdog.on_fresh_input(ms(800), ms(1_000)).unwrap());
        assert_eq!(watchdog.tick(ms(1_049)).phase, WatchdogPhase::Active);
        assert_eq!(watchdog.tick(ms(1_050)).event, WatchdogEvent::Neutralized);
    }

    #[test]
    fn sample_older_than_the_neutral_window_is_never_enabled() {
        let mut watchdog = Watchdog::new(DEFAULT_NEUTRAL_MS).unwrap();
        watchdog.activate(0);

        assert_eq!(
            watchdog.on_fresh_input(0, ms(300)),
            Err(ProtocolError::WatchdogNotRearmable)
        );
        assert_eq!(watchdog.phase(), WatchdogPhase::Neutral);
        assert!(!watchdog.output_allowed());
    }

    #[test]
    fn stale_sample_cannot_move_the_reference_backwards() {
        let mut watchdog = Watchdog::new(DEFAULT_NEUTRAL_MS).unwrap();
        watchdog.activate(ms(500));
        watchdog.on_fresh_input(ms(500), ms(500)).unwrap();
        assert_eq!(
            watchdog.on_fresh_input(ms(400), ms(501)),
            Err(ProtocolError::StaleSampleTime)
        );
        assert_eq!(watchdog.reference_us(), ms(500));
    }

    #[test]
    fn input_cannot_rearm_after_neutralization() {
        let mut watchdog = Watchdog::new(DEFAULT_NEUTRAL_MS).unwrap();
        watchdog.activate(0);
        watchdog.tick(ms(250));
        assert_eq!(
            watchdog.on_fresh_input(ms(300), ms(300)),
            Err(ProtocolError::WatchdogNotRearmable)
        );
    }

    #[test]
    fn rearm_requires_a_neutral_baseline_then_fresh_input() {
        let mut watchdog = Watchdog::new(DEFAULT_NEUTRAL_MS).unwrap();
        watchdog.activate(0);
        watchdog.tick(ms(250));

        watchdog.rearm(ms(300)).unwrap();
        assert_eq!(watchdog.phase(), WatchdogPhase::Active);
        assert!(!watchdog.output_allowed());
        assert!(watchdog.on_fresh_input(ms(300), ms(300)).unwrap());
        assert!(watchdog.output_allowed());
    }

    #[test]
    fn expired_watchdog_cannot_rearm() {
        let mut watchdog = Watchdog::new(DEFAULT_NEUTRAL_MS).unwrap();
        watchdog.activate(0);
        watchdog.tick(ms(30_000));
        assert_eq!(
            watchdog.rearm(ms(30_001)),
            Err(ProtocolError::WatchdogNotRearmable)
        );
    }

    #[test]
    fn explicit_neutralization_does_not_extend_resume_deadline() {
        let mut watchdog = Watchdog::new(DEFAULT_NEUTRAL_MS).unwrap();
        watchdog.activate(ms(1_000));
        watchdog.on_fresh_input(ms(1_000), ms(1_000)).unwrap();
        watchdog.neutralize_now();
        assert_eq!(watchdog.tick(ms(6_000)).phase, WatchdogPhase::Reconnecting);
        assert_eq!(watchdog.tick(ms(31_000)).phase, WatchdogPhase::Expired);
    }

    #[test]
    fn transitions_are_reported_once() {
        let mut watchdog = Watchdog::new(DEFAULT_NEUTRAL_MS).unwrap();
        watchdog.activate(0);
        assert_eq!(watchdog.tick(ms(250)).event, WatchdogEvent::Neutralized);
        assert_eq!(watchdog.tick(ms(251)).event, WatchdogEvent::None);
        assert_eq!(watchdog.tick(ms(5_000)).event, WatchdogEvent::Reconnecting);
        assert_eq!(watchdog.tick(ms(5_001)).event, WatchdogEvent::None);
        assert_eq!(watchdog.tick(ms(30_000)).event, WatchdogEvent::Expired);
        assert_eq!(watchdog.tick(ms(30_001)).event, WatchdogEvent::None);
    }

    #[test]
    fn a_large_tick_jumps_to_the_highest_deadline() {
        let mut watchdog = Watchdog::new(DEFAULT_NEUTRAL_MS).unwrap();
        watchdog.activate(0);
        let tick = watchdog.tick(ms(30_000));
        assert_eq!(tick.event, WatchdogEvent::Expired);
        assert_eq!(tick.phase, WatchdogPhase::Expired);
    }
}
