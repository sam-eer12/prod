//! Bounded pre-authentication codecs. All inner integers are LE; the two-byte
//! outer length is BE and counts magic, version/type, and payload only.
//! Decoding a message does not authenticate it or authorize a consent action.

use super::{CONFIRMATION_LEN, PAKE_POINT_LEN, PAKE_SUITE};
use crate::crypto::SessionId;
use crate::{MAGIC, MAX_HANDSHAKE_FRAME_LEN, PROTOCOL_VERSION, ProtocolError, WIRE_VERSION};

/// Maximum UTF-8 desktop label size in bytes.
pub const MAX_LABEL_LEN: usize = 64;

#[derive(Clone, PartialEq, Eq)]
pub struct PairingRequest {
    pub version: u16,
    pub suite: u16,
    pub request_id: [u8; 16],
    pub desktop_nonce: [u8; 16],
    /// Unverified display text. It is never a cryptographic identity.
    pub desktop_label: String,
}

impl PairingRequest {
    pub fn validate(&self) -> Result<(), ProtocolError> {
        validate_selection(self.version, self.suite)?;
        validate_label(&self.desktop_label)
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct PairingAccept {
    pub version: u16,
    pub suite: u16,
    pub request_id: [u8; 16],
    pub phone_nonce: [u8; 16],
    pub session_id: SessionId,
}

/// Plaintext handshake messages. Debug output deliberately omits transcript
/// material. Passwords and session roots never appear in these messages.
#[derive(Clone, PartialEq, Eq)]
pub enum PairingMessage {
    Request(PairingRequest),
    Accept(PairingAccept),
    PakeA {
        request_id: [u8; 16],
        point: [u8; PAKE_POINT_LEN],
    },
    PakeB {
        request_id: [u8; 16],
        point: [u8; PAKE_POINT_LEN],
        confirmation: [u8; CONFIRMATION_LEN],
    },
    ConfirmA {
        request_id: [u8; 16],
        confirmation: [u8; CONFIRMATION_LEN],
    },
    Abort {
        request_id: [u8; 16],
        reason: u8,
    },
}

impl PairingMessage {
    pub const fn message_type(&self) -> u8 {
        match self {
            Self::Request(_) => 1,
            Self::Accept(_) => 2,
            Self::PakeA { .. } => 3,
            Self::PakeB { .. } => 4,
            Self::ConfirmA { .. } => 5,
            Self::Abort { .. } => 6,
        }
    }

    pub const fn request_id(&self) -> &[u8; 16] {
        match self {
            Self::Request(request) => &request.request_id,
            Self::Accept(accept) => &accept.request_id,
            Self::PakeA { request_id, .. }
            | Self::PakeB { request_id, .. }
            | Self::ConfirmA { request_id, .. }
            | Self::Abort { request_id, .. } => request_id,
        }
    }

    /// Encodes one complete pre-auth frame, including its length prefix.
    pub fn encode(&self) -> Result<Vec<u8>, ProtocolError> {
        let mut bytes = vec![0, 0, MAGIC, (WIRE_VERSION << 4) | self.message_type()];
        match self {
            Self::Request(request) => {
                request.validate()?;
                bytes.extend_from_slice(&request.version.to_le_bytes());
                bytes.extend_from_slice(&request.suite.to_le_bytes());
                bytes.extend_from_slice(&request.request_id);
                bytes.extend_from_slice(&request.desktop_nonce);
                bytes.extend_from_slice(&(request.desktop_label.len() as u16).to_le_bytes());
                bytes.extend_from_slice(request.desktop_label.as_bytes());
            }
            Self::Accept(accept) => {
                validate_selection(accept.version, accept.suite)?;
                bytes.extend_from_slice(&accept.version.to_le_bytes());
                bytes.extend_from_slice(&accept.suite.to_le_bytes());
                bytes.extend_from_slice(&accept.request_id);
                bytes.extend_from_slice(&accept.phone_nonce);
                bytes.extend_from_slice(accept.session_id.as_bytes());
            }
            Self::PakeA { request_id, point } => {
                bytes.extend_from_slice(request_id);
                bytes.extend_from_slice(point);
            }
            Self::PakeB {
                request_id,
                point,
                confirmation,
            } => {
                bytes.extend_from_slice(request_id);
                bytes.extend_from_slice(point);
                bytes.extend_from_slice(confirmation);
            }
            Self::ConfirmA {
                request_id,
                confirmation,
            } => {
                bytes.extend_from_slice(request_id);
                bytes.extend_from_slice(confirmation);
            }
            Self::Abort { request_id, reason } => {
                bytes.extend_from_slice(request_id);
                bytes.push(*reason);
            }
        }
        let length = bytes.len() - 2;
        let prefix = (length as u16).to_be_bytes();
        preauth_body_len(prefix)?;
        bytes[..2].copy_from_slice(&prefix);
        Ok(bytes)
    }

    /// Checks the outer bound and exact type-specific length before allocation.
    pub fn decode(bytes: &[u8]) -> Result<Self, ProtocolError> {
        if bytes.len() < 4 {
            return Err(ProtocolError::TruncatedFrame {
                len: bytes.len(),
                minimum: 4,
            });
        }
        if bytes.len() > MAX_HANDSHAKE_FRAME_LEN {
            return Err(ProtocolError::OversizedFrame {
                len: bytes.len(),
                maximum: MAX_HANDSHAKE_FRAME_LEN,
            });
        }
        let length = preauth_body_len([bytes[0], bytes[1]])?;
        let kind = bytes[3] & 0x0f;
        if bytes.len() != length + 2 {
            return Err(ProtocolError::InvalidLength {
                frame_type: kind,
                len: bytes.len(),
            });
        }
        if bytes[2] != MAGIC {
            return Err(ProtocolError::BadMagic(bytes[2]));
        }
        if bytes[3] >> 4 != WIRE_VERSION {
            return Err(ProtocolError::UnsupportedVersion(bytes[3] >> 4));
        }
        let payload = &bytes[4..];
        match kind {
            1 => {
                if payload.len() < 38 {
                    return Err(invalid_length(kind, payload));
                }
                let label_len = u16::from_le_bytes(fixed(payload, 36)?) as usize;
                if label_len > MAX_LABEL_LEN {
                    return Err(ProtocolError::InvalidLabel);
                }
                if payload.len() != 38 + label_len {
                    return Err(invalid_length(kind, payload));
                }
                let label =
                    std::str::from_utf8(&payload[38..]).map_err(|_| ProtocolError::InvalidLabel)?;
                validate_label(label)?;
                let request = PairingRequest {
                    version: u16::from_le_bytes(fixed(payload, 0)?),
                    suite: u16::from_le_bytes(fixed(payload, 2)?),
                    request_id: fixed(payload, 4)?,
                    desktop_nonce: fixed(payload, 20)?,
                    desktop_label: label.to_owned(),
                };
                request.validate()?;
                Ok(Self::Request(request))
            }
            2 => {
                exact(kind, payload, 52)?;
                let accept = PairingAccept {
                    version: u16::from_le_bytes(fixed(payload, 0)?),
                    suite: u16::from_le_bytes(fixed(payload, 2)?),
                    request_id: fixed(payload, 4)?,
                    phone_nonce: fixed(payload, 20)?,
                    session_id: SessionId::from_bytes(fixed(payload, 36)?),
                };
                validate_selection(accept.version, accept.suite)?;
                Ok(Self::Accept(accept))
            }
            3 => {
                exact(kind, payload, 81)?;
                Ok(Self::PakeA {
                    request_id: fixed(payload, 0)?,
                    point: fixed(payload, 16)?,
                })
            }
            4 => {
                exact(kind, payload, 113)?;
                Ok(Self::PakeB {
                    request_id: fixed(payload, 0)?,
                    point: fixed(payload, 16)?,
                    confirmation: fixed(payload, 81)?,
                })
            }
            5 => {
                exact(kind, payload, 48)?;
                Ok(Self::ConfirmA {
                    request_id: fixed(payload, 0)?,
                    confirmation: fixed(payload, 16)?,
                })
            }
            6 => {
                exact(kind, payload, 17)?;
                Ok(Self::Abort {
                    request_id: fixed(payload, 0)?,
                    reason: payload[16],
                })
            }
            other => Err(ProtocolError::UnknownFrameType(other)),
        }
    }
}

impl std::fmt::Debug for PairingMessage {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "PairingMessage(type={}, [transcript redacted])",
            self.message_type()
        )
    }
}

/// Validates a received prefix before a transport allocates/reads its body.
pub fn preauth_body_len(prefix: [u8; 2]) -> Result<usize, ProtocolError> {
    let length = u16::from_be_bytes(prefix) as usize;
    if length < 2 {
        return Err(ProtocolError::TruncatedFrame {
            len: length,
            minimum: 2,
        });
    }
    if length + 2 > MAX_HANDSHAKE_FRAME_LEN {
        return Err(ProtocolError::OversizedFrame {
            len: length + 2,
            maximum: MAX_HANDSHAKE_FRAME_LEN,
        });
    }
    Ok(length)
}

pub(crate) fn validate_selection(version: u16, suite: u16) -> Result<(), ProtocolError> {
    if version != PROTOCOL_VERSION {
        return Err(ProtocolError::UnsupportedVersion((version & 0xff) as u8));
    }
    if suite != PAKE_SUITE {
        return Err(ProtocolError::UnsupportedSuite(suite));
    }
    Ok(())
}

pub(crate) fn validate_label(label: &str) -> Result<(), ProtocolError> {
    if label.trim().is_empty()
        || label.len() > MAX_LABEL_LEN
        || label.chars().any(|c| {
            c.is_control() || matches!(c, '\u{2028}'..='\u{202e}' | '\u{2066}'..='\u{2069}')
        })
    {
        return Err(ProtocolError::InvalidLabel);
    }
    Ok(())
}

fn fixed<const N: usize>(bytes: &[u8], offset: usize) -> Result<[u8; N], ProtocolError> {
    bytes
        .get(offset..offset + N)
        .and_then(|value| value.try_into().ok())
        .ok_or(ProtocolError::TruncatedFrame {
            len: bytes.len(),
            minimum: offset + N,
        })
}
fn invalid_length(kind: u8, payload: &[u8]) -> ProtocolError {
    ProtocolError::InvalidLength {
        frame_type: kind,
        len: payload.len(),
    }
}
fn exact(kind: u8, payload: &[u8], len: usize) -> Result<(), ProtocolError> {
    if payload.len() == len {
        Ok(())
    } else {
        Err(invalid_length(kind, payload))
    }
}
