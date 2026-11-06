//! Pinned SPAKE2 pairing core, without sockets or an Android consent UI.
//!
//! Suite 1 uses pakery's RFC 9382 P-256 suite, conformance-tested against
//! Appendix B. The dependencies are not independently audited. This module
//! does not establish live-input safety, platform support, or a memory cap.
//! The phone must call `PhoneHandshake::consent` only after a real Allow action.

mod handshake;
mod pake;
mod random;
mod session;
pub mod wire;

pub use handshake::{DesktopHandshake, PhoneHandshake};
pub use session::{PairedSession, Role};
pub use wire::{PairingMessage, PairingRequest};

/// Pinned SPAKE2 P-256 / SHA-256 / HKDF-SHA256 / HMAC-SHA256 suite.
pub const PAKE_SUITE: u16 = 1;
/// Canonical SEC1 uncompressed P-256 point size.
pub const PAKE_POINT_LEN: usize = 65;
/// Full HMAC-SHA256 confirmation size.
pub const CONFIRMATION_LEN: usize = 32;
