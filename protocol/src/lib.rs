//! Shared PadLink protocol, session rules, and crypto core.
//!
//! This crate is the single source of truth for:
//!
//! - six-character pairing-code shape, generation, and attempt limits;
//! - exact State/Edges/Ack/control frame layouts;
//! - HKDF traffic-key derivation and ChaCha20-Poly1305 envelopes;
//! - per-key replay windows and sequence limits;
//! - the bounded digital-edge journal and receiver reordering;
//! - conservative clock bounds, input freshness, and the input watchdog.
//!
//! It deliberately does **not** implement the PAKE handshake, discovery,
//! sockets, native gamepad backends, or a daemon. Pairing must remain blocked
//! until a reviewed PAKE implementation consumes [`code::PairingToken`] and
//! produces the session root and ID used here.
//!
//! See `protocol/SPEC.md` for the normative wire contract.

pub mod clock;
pub mod code;
pub mod crypto;
pub mod edge;
pub mod error;
pub mod frame;
pub mod input;
pub mod watchdog;

pub use code::{
    PAIRING_CODE_ALPHABET, PAIRING_CODE_LENGTH, PAIRING_MAX_ATTEMPTS, PAIRING_TOKEN_TTL_MS,
    PairingToken, generate_pairing_code, is_well_formed_pairing_code, normalize_pairing_code,
};
pub use error::ProtocolError;

/// Wire protocol revision. Bump when a change breaks interoperability.
pub const PROTOCOL_VERSION: u16 = 1;

/// Version nibble carried in every frame header.
pub const WIRE_VERSION: u8 = 1;

/// First byte of every encrypted frame.
pub const MAGIC: u8 = 0x50;

/// Default phone-hosted TCP pairing port.
pub const DEFAULT_PAIRING_PORT: u16 = 41_337;

/// Default UDP input port advertised after pairing.
pub const DEFAULT_UDP_PORT: u16 = 41_338;

/// Default State transmission rate.
pub const DEFAULT_STATE_HZ: u16 = 120;

/// Lowest negotiable State rate.
pub const MIN_STATE_HZ: u16 = 60;

/// Highest negotiable State rate.
pub const MAX_STATE_HZ: u16 = 240;

/// Maximum pre-authentication TCP handshake frame.
pub const MAX_HANDSHAKE_FRAME_LEN: usize = 4_096;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn protocol_revision_matches_the_wire_nibble() {
        assert_eq!(PROTOCOL_VERSION, WIRE_VERSION as u16);
    }

    #[test]
    fn default_rates_are_in_range() {
        const {
            assert!(MIN_STATE_HZ <= DEFAULT_STATE_HZ);
            assert!(DEFAULT_STATE_HZ <= MAX_STATE_HZ);
        }
    }
}
