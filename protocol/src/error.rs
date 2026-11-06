//! Fail-closed error types shared by every protocol stage.

use std::fmt;

/// A protocol, framing, pairing, or session-rule failure.
///
/// Every variant means the caller must not advance session state, inject input,
/// or accept the offending value. Errors deliberately carry no token, traffic
/// key, or transcript material.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProtocolError {
    ResourceExhausted,
    SessionExpired,
    ResumeState,
    ClockRegression,
    /// The frame is shorter than the fixed minimum for its type.
    TruncatedFrame {
        len: usize,
        minimum: usize,
    },
    /// The frame exceeds the authenticated frame-size budget.
    OversizedFrame {
        len: usize,
        maximum: usize,
    },
    /// The first frame byte was not [`crate::MAGIC`].
    BadMagic(u8),
    /// The header version nibble is not supported.
    UnsupportedVersion(u8),
    /// The header type nibble is not a known frame type.
    UnknownFrameType(u8),
    /// A frame with a valid type had the wrong payload length.
    InvalidLength {
        frame_type: u8,
        len: usize,
    },
    /// A field documented as reserved was not zero.
    ReservedNonZero {
        field: &'static str,
    },
    /// A field value is outside its documented range.
    ValueOutOfRange {
        field: &'static str,
    },
    /// AEAD authentication failed.
    AuthenticationFailed,
    /// The packet counter was already accepted under this key.
    ReplayedSequence {
        seq: u64,
    },
    /// The per-key counter reached the rekey threshold.
    SequenceExhausted,
    /// The routing tag did not match the active session.
    SessionTagMismatch,
    /// A pairing code did not have the required shape.
    InvalidPairingCode,
    /// The pairing token expired before verification.
    PairingTokenExpired,
    /// All pairing attempts were consumed; a new consent action is required.
    PairingTokenLocked,
    /// The submitted pairing code was wrong.
    PairingCodeMismatch {
        attempts_remaining: u8,
    },
    /// The peer offered or selected a pairing suite this build does not support.
    UnsupportedSuite(u16),
    /// A pairing label was empty, too long, or contained control characters.
    InvalidLabel,
    /// A pairing message did not match the active request or transcript.
    PairingRequestMismatch,
    /// A pairing message arrived in a state that cannot accept it.
    PairingState,
    /// The peer aborted the pairing request with a numeric reason.
    PairingAborted {
        reason: u8,
    },
    /// The password-authenticated exchange or its key confirmation failed.
    ///
    /// The variants deliberately collapse transcript, point, and confirmation
    /// failures so a caller cannot use the error as a guessing oracle.
    PakeFailed,
    /// The operating system random source failed.
    RandomUnavailable,
    /// The bounded digital-edge journal has no room for another transition.
    EdgeJournalFull {
        capacity: usize,
    },
    /// An edge ID is too far ahead of the receiver cursor.
    EdgeOutOfWindow {
        edge_id: u64,
        highest_contiguous: u64,
    },
    /// An acknowledgment named an edge the sender never issued.
    InvalidAcknowledgement {
        acknowledged: u64,
        highest_issued: u64,
    },
    /// The measured clock uncertainty is too large to reason about freshness.
    ClockUncertaintyTooLarge,
    /// A sample time is in the future beyond the measured clock bounds.
    FutureSampleTime,
    /// A sample is older than the most recent accepted sample.
    StaleSampleTime,
    /// The watchdog cannot rearm in its current phase.
    WatchdogNotRearmable,
    /// The requested operation or optional capability is unavailable.
    Unavailable(&'static str),
}

impl fmt::Display for ProtocolError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::ResourceExhausted => formatter.write_str("bounded protocol resource exhausted"),
            Self::SessionExpired => formatter.write_str("protocol session expired"),
            Self::ResumeState => formatter.write_str("invalid authenticated resume state"),
            Self::ClockRegression => {
                formatter.write_str("monotonic protocol clock moved backwards")
            }
            Self::TruncatedFrame { len, minimum } => {
                write!(formatter, "frame is {len} bytes; minimum is {minimum}")
            }
            Self::OversizedFrame { len, maximum } => {
                write!(formatter, "frame is {len} bytes; maximum is {maximum}")
            }
            Self::BadMagic(value) => write!(formatter, "bad frame magic 0x{value:02X}"),
            Self::UnsupportedVersion(version) => {
                write!(formatter, "unsupported protocol version {version}")
            }
            Self::UnknownFrameType(frame_type) => {
                write!(formatter, "unknown frame type {frame_type}")
            }
            Self::InvalidLength { frame_type, len } => {
                write!(
                    formatter,
                    "frame type {frame_type} has invalid length {len}"
                )
            }
            Self::ReservedNonZero { field } => {
                write!(formatter, "reserved field `{field}` is not zero")
            }
            Self::ValueOutOfRange { field } => {
                write!(formatter, "field `{field}` is out of range")
            }
            Self::AuthenticationFailed => write!(formatter, "authentication failed"),
            Self::ReplayedSequence { seq } => write!(formatter, "replayed sequence {seq}"),
            Self::SequenceExhausted => write!(formatter, "packet counter requires rekeying"),
            Self::SessionTagMismatch => write!(formatter, "session routing tag mismatch"),
            Self::InvalidPairingCode => write!(formatter, "pairing code has invalid characters"),
            Self::PairingTokenExpired => write!(formatter, "pairing token expired"),
            Self::PairingTokenLocked => write!(formatter, "pairing token locked"),
            Self::PairingCodeMismatch { attempts_remaining } => {
                write!(
                    formatter,
                    "pairing code mismatch; {attempts_remaining} attempts remain"
                )
            }
            Self::UnsupportedSuite(suite) => write!(formatter, "unsupported pairing suite {suite}"),
            Self::InvalidLabel => write!(formatter, "pairing label is invalid"),
            Self::PairingRequestMismatch => write!(formatter, "pairing request does not match"),
            Self::PairingState => write!(formatter, "pairing message is invalid in this state"),
            Self::PairingAborted { reason } => {
                write!(formatter, "pairing aborted (reason {reason})")
            }
            Self::PakeFailed => write!(formatter, "password-authenticated exchange failed"),
            Self::RandomUnavailable => write!(formatter, "system random source unavailable"),
            Self::EdgeJournalFull { capacity } => {
                write!(formatter, "digital-edge journal full ({capacity} entries)")
            }
            Self::EdgeOutOfWindow {
                edge_id,
                highest_contiguous,
            } => write!(
                formatter,
                "edge {edge_id} is outside the window after {highest_contiguous}"
            ),
            Self::InvalidAcknowledgement {
                acknowledged,
                highest_issued,
            } => write!(
                formatter,
                "edge acknowledgement {acknowledged} exceeds highest issued {highest_issued}"
            ),
            Self::ClockUncertaintyTooLarge => {
                write!(
                    formatter,
                    "clock uncertainty is too large to establish freshness"
                )
            }
            Self::FutureSampleTime => write!(formatter, "sample time is implausibly in the future"),
            Self::StaleSampleTime => write!(formatter, "sample time moved backwards"),
            Self::WatchdogNotRearmable => write!(formatter, "watchdog is not in a rearmable phase"),
            Self::Unavailable(reason) => write!(formatter, "unavailable: {reason}"),
        }
    }
}

impl std::error::Error for ProtocolError {}
