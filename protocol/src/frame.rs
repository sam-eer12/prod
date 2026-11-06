//! Versioned wire frames shared by the phone and desktop.
//!
//! The clear header and the encrypted payload are handled separately. A frame
//! on the wire is `header || ciphertext || tag`; see [`crate::crypto`] for the
//! authenticated envelope. This module only defines and validates the inner
//! payload formats.

use crate::error::ProtocolError;
use crate::{MAGIC, WIRE_VERSION};

/// Bytes in the authenticated clear header.
pub const HEADER_LEN: usize = 12;
/// Bytes in the Poly1305 authentication tag.
pub const TAG_LEN: usize = 16;
/// Maximum on-wire encrypted frame size.
pub const MAX_FRAME_LEN: usize = 256;
/// Maximum encrypted payload size (`MAX_FRAME_LEN - HEADER_LEN - TAG_LEN`).
pub const MAX_PAYLOAD_LEN: usize = MAX_FRAME_LEN - HEADER_LEN - TAG_LEN;
/// Exact State payload size.
pub const STATE_PAYLOAD_LEN: usize = 28;
/// Maximum digital transitions carried by one Edges frame.
pub const MAX_EDGES_PER_FRAME: usize = 12;
/// Maximum Edges payload size.
pub const MAX_EDGES_PAYLOAD_LEN: usize = 2 + MAX_EDGES_PER_FRAME * 18;
/// Maximum time a remote rumble command may run.
pub const MAX_RUMBLE_MS: u16 = 1_000;

/// Frame type nibble values.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum FrameType {
    State = 1,
    Edges = 2,
    Ack = 3,
    Ping = 4,
    Pong = 5,
    Rumble = 6,
    Disconnect = 7,
    EpochConfirm = 8,
    Error = 9,
    ResumeChallenge = 10,
    ResumeConfirm = 11,
}

impl FrameType {
    /// All currently defined frame types, for parser tests and diagnostics.
    pub const ALL: [Self; 11] = [
        Self::State,
        Self::Edges,
        Self::Ack,
        Self::Ping,
        Self::Pong,
        Self::Rumble,
        Self::Disconnect,
        Self::EpochConfirm,
        Self::Error,
        Self::ResumeChallenge,
        Self::ResumeConfirm,
    ];

    /// Numeric type nibble.
    pub const fn as_u8(self) -> u8 {
        self as u8
    }

    /// Maximum allowed payload length for this type.
    pub const fn max_payload_len(self) -> usize {
        match self {
            Self::State => STATE_PAYLOAD_LEN,
            Self::Edges => MAX_EDGES_PAYLOAD_LEN,
            Self::Ack => 8,
            Self::Ping => 16,
            Self::Pong => 32,
            Self::Rumble => 4,
            Self::Disconnect => 1,
            Self::EpochConfirm => 16,
            Self::Error => 4,
            Self::ResumeChallenge => 20,
            Self::ResumeConfirm => 52,
        }
    }
}

impl TryFrom<u8> for FrameType {
    type Error = ProtocolError;

    fn try_from(value: u8) -> Result<Self, ProtocolError> {
        match value {
            1 => Ok(Self::State),
            2 => Ok(Self::Edges),
            3 => Ok(Self::Ack),
            4 => Ok(Self::Ping),
            5 => Ok(Self::Pong),
            6 => Ok(Self::Rumble),
            7 => Ok(Self::Disconnect),
            8 => Ok(Self::EpochConfirm),
            9 => Ok(Self::Error),
            10 => Ok(Self::ResumeChallenge),
            11 => Ok(Self::ResumeConfirm),
            other => Err(ProtocolError::UnknownFrameType(other)),
        }
    }
}

/// Authenticated clear header. The header is AEAD associated data.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Header {
    pub frame_type: FrameType,
    pub session_tag: u16,
    pub seq: u64,
}

impl Header {
    /// Serializes the fixed 12-byte header.
    pub const fn encode(&self) -> [u8; HEADER_LEN] {
        let mut bytes = [0_u8; HEADER_LEN];
        bytes[0] = MAGIC;
        bytes[1] = (WIRE_VERSION << 4) | self.frame_type.as_u8();
        let tag = self.session_tag.to_le_bytes();
        bytes[2] = tag[0];
        bytes[3] = tag[1];
        let seq = self.seq.to_le_bytes();
        let mut index = 0;
        while index < 8 {
            bytes[4 + index] = seq[index];
            index += 1;
        }
        bytes
    }

    /// Parses and validates the fixed 12-byte header.
    pub fn decode(bytes: &[u8]) -> Result<Self, ProtocolError> {
        if bytes.len() < HEADER_LEN {
            return Err(ProtocolError::TruncatedFrame {
                len: bytes.len(),
                minimum: HEADER_LEN,
            });
        }
        if bytes[0] != MAGIC {
            return Err(ProtocolError::BadMagic(bytes[0]));
        }

        let version = bytes[1] >> 4;
        if version != WIRE_VERSION {
            return Err(ProtocolError::UnsupportedVersion(version));
        }

        let frame_type = FrameType::try_from(bytes[1] & 0x0F)?;
        let session_tag = u16::from_le_bytes([bytes[2], bytes[3]]);
        let seq = u64::from_le_bytes(bytes[4..12].try_into().map_err(|_| {
            ProtocolError::TruncatedFrame {
                len: bytes.len(),
                minimum: HEADER_LEN,
            }
        })?);

        Ok(Self {
            frame_type,
            session_tag,
            seq,
        })
    }
}

/// Gamepad buttons carried by a state snapshot or a digital edge.
///
/// Bit 15 is reserved and must be zero. A/B/X/Y, shoulders, Back/Start/Guide,
/// L3/R3, and the four D-pad directions are the only defined bits.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash)]
pub struct Buttons(u16);

impl Buttons {
    pub const A: Self = Self(1 << 0);
    pub const B: Self = Self(1 << 1);
    pub const X: Self = Self(1 << 2);
    pub const Y: Self = Self(1 << 3);
    pub const LEFT_BUMPER: Self = Self(1 << 4);
    pub const RIGHT_BUMPER: Self = Self(1 << 5);
    pub const BACK: Self = Self(1 << 6);
    pub const START: Self = Self(1 << 7);
    pub const GUIDE: Self = Self(1 << 8);
    pub const LEFT_STICK: Self = Self(1 << 9);
    pub const RIGHT_STICK: Self = Self(1 << 10);
    pub const DPAD_UP: Self = Self(1 << 11);
    pub const DPAD_DOWN: Self = Self(1 << 12);
    pub const DPAD_LEFT: Self = Self(1 << 13);
    pub const DPAD_RIGHT: Self = Self(1 << 14);

    const RESERVED: u16 = 1 << 15;

    /// Neutral state: no buttons pressed.
    pub const fn neutral() -> Self {
        Self(0)
    }

    /// Raw wire bits.
    pub const fn bits(self) -> u16 {
        self.0
    }

    /// Builds a button set, rejecting the reserved bit.
    pub const fn from_bits(bits: u16) -> Result<Self, ProtocolError> {
        if bits & Self::RESERVED != 0 {
            return Err(ProtocolError::ReservedNonZero {
                field: "buttons.bit15",
            });
        }
        Ok(Self(bits))
    }

    /// Returns whether every bit in `other` is present.
    pub const fn contains(self, other: Self) -> bool {
        self.0 & other.0 == other.0
    }

    /// Adds the bits in `other`.
    pub fn insert(&mut self, other: Self) {
        self.0 |= other.0;
    }

    /// Removes the bits in `other`.
    pub fn remove(&mut self, other: Self) {
        self.0 &= !other.0;
    }
}

impl std::ops::BitOr for Buttons {
    type Output = Self;

    fn bitor(self, rhs: Self) -> Self::Output {
        Self(self.0 | rhs.0)
    }
}

impl std::ops::BitOrAssign for Buttons {
    fn bitor_assign(&mut self, rhs: Self) {
        self.0 |= rhs.0;
    }
}

/// Signed stick position. X grows right; Y grows down (SDL/HID convention).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Stick {
    pub x: i16,
    pub y: i16,
}

impl Stick {
    /// Centered stick.
    pub const NEUTRAL: Self = Self { x: 0, y: 0 };
}

/// Encrypted State payload. On the wire the complete State frame is 56 bytes.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct StatePayload {
    /// Latest digital transition incorporated into this snapshot.
    pub latest_edge_id: u64,
    /// Sender monotonic sample time in microseconds.
    pub sample_time_us: u64,
    pub buttons: Buttons,
    pub left_trigger: u8,
    pub right_trigger: u8,
    pub left_stick: Stick,
    pub right_stick: Stick,
}

impl StatePayload {
    /// Serializes the exact 28-byte payload.
    pub fn encode(&self) -> [u8; STATE_PAYLOAD_LEN] {
        let mut bytes = [0_u8; STATE_PAYLOAD_LEN];
        bytes[0..8].copy_from_slice(&self.latest_edge_id.to_le_bytes());
        bytes[8..16].copy_from_slice(&self.sample_time_us.to_le_bytes());
        bytes[16..18].copy_from_slice(&self.buttons.bits().to_le_bytes());
        bytes[18] = self.left_trigger;
        bytes[19] = self.right_trigger;
        bytes[20..22].copy_from_slice(&self.left_stick.x.to_le_bytes());
        bytes[22..24].copy_from_slice(&self.left_stick.y.to_le_bytes());
        bytes[24..26].copy_from_slice(&self.right_stick.x.to_le_bytes());
        bytes[26..28].copy_from_slice(&self.right_stick.y.to_le_bytes());
        bytes
    }

    /// Parses an exact 28-byte payload.
    pub fn decode(payload: &[u8]) -> Result<Self, ProtocolError> {
        expect_exact_len(FrameType::State, payload, STATE_PAYLOAD_LEN)?;

        Ok(Self {
            latest_edge_id: read_u64(payload, 0)?,
            sample_time_us: read_u64(payload, 8)?,
            buttons: Buttons::from_bits(read_u16(payload, 16)?)?,
            left_trigger: payload[18],
            right_trigger: payload[19],
            left_stick: Stick {
                x: read_i16(payload, 20)?,
                y: read_i16(payload, 22)?,
            },
            right_stick: Stick {
                x: read_i16(payload, 24)?,
                y: read_i16(payload, 26)?,
            },
        })
    }
}

/// One button-bitmap transition in the sender's ordered journal.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Edge {
    pub edge_id: u64,
    pub buttons: Buttons,
    pub event_time_us: u64,
}

/// Bounded batch of digital transitions.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EdgesPayload {
    pub entries: Vec<Edge>,
}

impl EdgesPayload {
    /// Serializes `1..=12` strictly increasing edge IDs.
    pub fn encode(&self) -> Result<Vec<u8>, ProtocolError> {
        if self.entries.is_empty() || self.entries.len() > MAX_EDGES_PER_FRAME {
            return Err(ProtocolError::ValueOutOfRange {
                field: "edges.entries",
            });
        }

        let mut bytes = Vec::with_capacity(2 + self.entries.len() * 18);
        bytes.push(self.entries.len() as u8);
        bytes.push(0);

        let mut previous = 0_u64;
        for edge in &self.entries {
            if edge.edge_id == 0 || edge.edge_id <= previous {
                return Err(ProtocolError::ValueOutOfRange {
                    field: "edges.edge_id",
                });
            }
            previous = edge.edge_id;
            bytes.extend_from_slice(&edge.edge_id.to_le_bytes());
            bytes.extend_from_slice(&edge.buttons.bits().to_le_bytes());
            bytes.extend_from_slice(&edge.event_time_us.to_le_bytes());
        }

        Ok(bytes)
    }

    /// Parses a bounded, strictly increasing edge batch.
    pub fn decode(payload: &[u8]) -> Result<Self, ProtocolError> {
        if payload.len() < 2 {
            return Err(ProtocolError::InvalidLength {
                frame_type: FrameType::Edges.as_u8(),
                len: payload.len(),
            });
        }
        if payload[1] != 0 {
            return Err(ProtocolError::ReservedNonZero {
                field: "edges.reserved",
            });
        }

        let count = payload[0] as usize;
        if !(1..=MAX_EDGES_PER_FRAME).contains(&count) {
            return Err(ProtocolError::ValueOutOfRange {
                field: "edges.count",
            });
        }
        if payload.len() != 2 + count * 18 {
            return Err(ProtocolError::InvalidLength {
                frame_type: FrameType::Edges.as_u8(),
                len: payload.len(),
            });
        }

        let mut entries = Vec::with_capacity(count);
        let mut previous = 0_u64;
        for index in 0..count {
            let offset = 2 + index * 18;
            let edge_id = read_u64(payload, offset)?;
            if edge_id == 0 || edge_id <= previous {
                return Err(ProtocolError::ValueOutOfRange {
                    field: "edges.edge_id",
                });
            }
            previous = edge_id;
            entries.push(Edge {
                edge_id,
                buttons: Buttons::from_bits(read_u16(payload, offset + 8)?)?,
                event_time_us: read_u64(payload, offset + 10)?,
            });
        }

        Ok(Self { entries })
    }
}

/// Highest contiguously delivered digital edge.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct AckPayload {
    pub highest_contiguous_edge_id: u64,
}

impl AckPayload {
    pub const LEN: usize = 8;

    pub fn encode(self) -> [u8; Self::LEN] {
        self.highest_contiguous_edge_id.to_le_bytes()
    }

    pub fn decode(payload: &[u8]) -> Result<Self, ProtocolError> {
        expect_exact_len(FrameType::Ack, payload, Self::LEN)?;
        Ok(Self {
            highest_contiguous_edge_id: read_u64(payload, 0)?,
        })
    }
}

/// Authenticated clock exchange request.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PingPayload {
    pub ping_id: u64,
    pub sent_time_us: u64,
}

impl PingPayload {
    pub const LEN: usize = 16;

    pub fn encode(self) -> [u8; Self::LEN] {
        let mut bytes = [0_u8; Self::LEN];
        bytes[0..8].copy_from_slice(&self.ping_id.to_le_bytes());
        bytes[8..16].copy_from_slice(&self.sent_time_us.to_le_bytes());
        bytes
    }

    pub fn decode(payload: &[u8]) -> Result<Self, ProtocolError> {
        expect_exact_len(FrameType::Ping, payload, Self::LEN)?;
        Ok(Self {
            ping_id: read_u64(payload, 0)?,
            sent_time_us: read_u64(payload, 8)?,
        })
    }
}

/// Authenticated clock exchange reply. All times are receiver monotonic.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PongPayload {
    pub ping_id: u64,
    pub echo_time_us: u64,
    pub received_time_us: u64,
    pub sent_time_us: u64,
}

impl PongPayload {
    pub const LEN: usize = 32;

    pub fn encode(self) -> [u8; Self::LEN] {
        let mut bytes = [0_u8; Self::LEN];
        bytes[0..8].copy_from_slice(&self.ping_id.to_le_bytes());
        bytes[8..16].copy_from_slice(&self.echo_time_us.to_le_bytes());
        bytes[16..24].copy_from_slice(&self.received_time_us.to_le_bytes());
        bytes[24..32].copy_from_slice(&self.sent_time_us.to_le_bytes());
        bytes
    }

    pub fn decode(payload: &[u8]) -> Result<Self, ProtocolError> {
        expect_exact_len(FrameType::Pong, payload, Self::LEN)?;
        Ok(Self {
            ping_id: read_u64(payload, 0)?,
            echo_time_us: read_u64(payload, 8)?,
            received_time_us: read_u64(payload, 16)?,
            sent_time_us: read_u64(payload, 24)?,
        })
    }
}

/// Bounded rumble request.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RumblePayload {
    pub left: u8,
    pub right: u8,
    pub duration_ms: u16,
}

impl RumblePayload {
    pub const LEN: usize = 4;

    pub fn encode(self) -> Result<[u8; Self::LEN], ProtocolError> {
        if self.duration_ms > MAX_RUMBLE_MS {
            return Err(ProtocolError::ValueOutOfRange {
                field: "rumble.duration_ms",
            });
        }
        let mut bytes = [0_u8; Self::LEN];
        bytes[0] = self.left;
        bytes[1] = self.right;
        bytes[2..4].copy_from_slice(&self.duration_ms.to_le_bytes());
        Ok(bytes)
    }

    pub fn decode(payload: &[u8]) -> Result<Self, ProtocolError> {
        expect_exact_len(FrameType::Rumble, payload, Self::LEN)?;
        let duration_ms = read_u16(payload, 2)?;
        if duration_ms > MAX_RUMBLE_MS {
            return Err(ProtocolError::ValueOutOfRange {
                field: "rumble.duration_ms",
            });
        }
        Ok(Self {
            left: payload[0],
            right: payload[1],
            duration_ms,
        })
    }
}

/// Why a peer ended the session.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DisconnectReason {
    UserRequested,
    PhonePaused,
    DesktopLocked,
    BackendLost,
    SessionExpired,
    MemoryPressure,
    ProtocolViolation,
    Other(u8),
}

impl DisconnectReason {
    const fn code(self) -> u8 {
        match self {
            Self::UserRequested => 1,
            Self::PhonePaused => 2,
            Self::DesktopLocked => 3,
            Self::BackendLost => 4,
            Self::SessionExpired => 5,
            Self::MemoryPressure => 6,
            Self::ProtocolViolation => 7,
            Self::Other(code) => code,
        }
    }

    const fn from_code(code: u8) -> Self {
        match code {
            1 => Self::UserRequested,
            2 => Self::PhonePaused,
            3 => Self::DesktopLocked,
            4 => Self::BackendLost,
            5 => Self::SessionExpired,
            6 => Self::MemoryPressure,
            7 => Self::ProtocolViolation,
            other => Self::Other(other),
        }
    }
}

/// Session teardown frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DisconnectPayload {
    pub reason: DisconnectReason,
}

impl DisconnectPayload {
    pub const LEN: usize = 1;

    pub const fn encode(self) -> [u8; Self::LEN] {
        [self.reason.code()]
    }

    pub fn decode(payload: &[u8]) -> Result<Self, ProtocolError> {
        expect_exact_len(FrameType::Disconnect, payload, Self::LEN)?;
        Ok(Self {
            reason: DisconnectReason::from_code(payload[0]),
        })
    }
}

/// Confirms a fresh neutral input epoch.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EpochConfirmPayload {
    pub epoch: u32,
    pub baseline_edge_id: u64,
    pub flags: u16,
}

impl EpochConfirmPayload {
    pub const LEN: usize = 16;
    /// The sender has cleared all controls and accepted the new epoch.
    pub const FLAG_NEUTRAL_BASELINE: u16 = 1 << 0;

    pub fn encode(self) -> Result<[u8; Self::LEN], ProtocolError> {
        if self.baseline_edge_id != 0 {
            return Err(ProtocolError::ValueOutOfRange {
                field: "epoch.baseline_edge_id",
            });
        }
        if self.flags & !Self::FLAG_NEUTRAL_BASELINE != 0 {
            return Err(ProtocolError::ValueOutOfRange {
                field: "epoch.flags",
            });
        }

        let mut bytes = [0_u8; Self::LEN];
        bytes[0..4].copy_from_slice(&self.epoch.to_le_bytes());
        bytes[4..12].copy_from_slice(&self.baseline_edge_id.to_le_bytes());
        bytes[12..14].copy_from_slice(&self.flags.to_le_bytes());
        // bytes[14..16] is reserved zero.
        Ok(bytes)
    }

    pub fn decode(payload: &[u8]) -> Result<Self, ProtocolError> {
        expect_exact_len(FrameType::EpochConfirm, payload, Self::LEN)?;
        if read_u16(payload, 14)? != 0 {
            return Err(ProtocolError::ReservedNonZero {
                field: "epoch.reserved",
            });
        }
        let flags = read_u16(payload, 12)?;
        if flags & !Self::FLAG_NEUTRAL_BASELINE != 0 {
            return Err(ProtocolError::ValueOutOfRange {
                field: "epoch.flags",
            });
        }
        let baseline_edge_id = read_u64(payload, 4)?;
        if baseline_edge_id != 0 {
            return Err(ProtocolError::ValueOutOfRange {
                field: "epoch.baseline_edge_id",
            });
        }

        Ok(Self {
            epoch: u32::from_le_bytes(payload[0..4].try_into().map_err(|_| {
                ProtocolError::InvalidLength {
                    frame_type: FrameType::EpochConfirm.as_u8(),
                    len: payload.len(),
                }
            })?),
            baseline_edge_id,
            flags,
        })
    }
}

/// A protocol error sent by a peer. The numeric code is informational only;
/// the receiver still fails closed on any violation it detects independently.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ErrorPayload {
    pub code: u16,
    pub detail: u16,
}

impl ErrorPayload {
    pub const LEN: usize = 4;

    pub fn encode(self) -> [u8; Self::LEN] {
        let mut bytes = [0_u8; Self::LEN];
        bytes[0..2].copy_from_slice(&self.code.to_le_bytes());
        bytes[2..4].copy_from_slice(&self.detail.to_le_bytes());
        bytes
    }

    pub fn decode(payload: &[u8]) -> Result<Self, ProtocolError> {
        expect_exact_len(FrameType::Error, payload, Self::LEN)?;
        Ok(Self {
            code: read_u16(payload, 0)?,
            detail: read_u16(payload, 2)?,
        })
    }
}

/// First message of the authenticated endpoint/epoch migration handshake.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ResumeChallengePayload {
    pub epoch: u32,
    pub challenge: [u8; 16],
}

impl ResumeChallengePayload {
    pub const LEN: usize = 20;

    pub fn encode(self) -> [u8; Self::LEN] {
        let mut bytes = [0_u8; Self::LEN];
        bytes[0..4].copy_from_slice(&self.epoch.to_le_bytes());
        bytes[4..20].copy_from_slice(&self.challenge);
        bytes
    }

    pub fn decode(payload: &[u8]) -> Result<Self, ProtocolError> {
        expect_exact_len(FrameType::ResumeChallenge, payload, Self::LEN)?;
        Ok(Self {
            epoch: u32::from_le_bytes(payload[0..4].try_into().map_err(|_| {
                ProtocolError::InvalidLength {
                    frame_type: FrameType::ResumeChallenge.as_u8(),
                    len: payload.len(),
                }
            })?),
            challenge: payload[4..20]
                .try_into()
                .map_err(|_| ProtocolError::InvalidLength {
                    frame_type: FrameType::ResumeChallenge.as_u8(),
                    len: payload.len(),
                })?,
        })
    }
}

/// Mutual confirmation message for an endpoint/epoch migration.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ResumeConfirmPayload {
    pub epoch: u32,
    pub challenge_echo: [u8; 16],
    pub mac: [u8; 32],
}

impl ResumeConfirmPayload {
    pub const LEN: usize = 52;

    pub fn encode(self) -> [u8; Self::LEN] {
        let mut bytes = [0_u8; Self::LEN];
        bytes[0..4].copy_from_slice(&self.epoch.to_le_bytes());
        bytes[4..20].copy_from_slice(&self.challenge_echo);
        bytes[20..52].copy_from_slice(&self.mac);
        bytes
    }

    pub fn decode(payload: &[u8]) -> Result<Self, ProtocolError> {
        expect_exact_len(FrameType::ResumeConfirm, payload, Self::LEN)?;
        Ok(Self {
            epoch: u32::from_le_bytes(payload[0..4].try_into().map_err(|_| {
                ProtocolError::InvalidLength {
                    frame_type: FrameType::ResumeConfirm.as_u8(),
                    len: payload.len(),
                }
            })?),
            challenge_echo: payload[4..20].try_into().map_err(|_| {
                ProtocolError::InvalidLength {
                    frame_type: FrameType::ResumeConfirm.as_u8(),
                    len: payload.len(),
                }
            })?,
            mac: payload[20..52]
                .try_into()
                .map_err(|_| ProtocolError::InvalidLength {
                    frame_type: FrameType::ResumeConfirm.as_u8(),
                    len: payload.len(),
                })?,
        })
    }
}

/// A decoded frame payload.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Frame {
    State(StatePayload),
    Edges(EdgesPayload),
    Ack(AckPayload),
    Ping(PingPayload),
    Pong(PongPayload),
    Rumble(RumblePayload),
    Disconnect(DisconnectPayload),
    EpochConfirm(EpochConfirmPayload),
    Error(ErrorPayload),
    ResumeChallenge(ResumeChallengePayload),
    ResumeConfirm(ResumeConfirmPayload),
}

impl Frame {
    /// The type nibble this frame carries.
    pub const fn frame_type(&self) -> FrameType {
        match self {
            Self::State(_) => FrameType::State,
            Self::Edges(_) => FrameType::Edges,
            Self::Ack(_) => FrameType::Ack,
            Self::Ping(_) => FrameType::Ping,
            Self::Pong(_) => FrameType::Pong,
            Self::Rumble(_) => FrameType::Rumble,
            Self::Disconnect(_) => FrameType::Disconnect,
            Self::EpochConfirm(_) => FrameType::EpochConfirm,
            Self::Error(_) => FrameType::Error,
            Self::ResumeChallenge(_) => FrameType::ResumeChallenge,
            Self::ResumeConfirm(_) => FrameType::ResumeConfirm,
        }
    }

    /// Serializes the inner payload after validating its bounds.
    pub fn encode_payload(&self) -> Result<Vec<u8>, ProtocolError> {
        let payload = match self {
            Self::State(state) => state.encode().to_vec(),
            Self::Edges(edges) => edges.encode()?,
            Self::Ack(ack) => ack.encode().to_vec(),
            Self::Ping(ping) => ping.encode().to_vec(),
            Self::Pong(pong) => pong.encode().to_vec(),
            Self::Rumble(rumble) => rumble.encode()?.to_vec(),
            Self::Disconnect(disconnect) => disconnect.encode().to_vec(),
            Self::EpochConfirm(epoch) => epoch.encode()?.to_vec(),
            Self::Error(error) => error.encode().to_vec(),
            Self::ResumeChallenge(challenge) => challenge.encode().to_vec(),
            Self::ResumeConfirm(confirm) => confirm.encode().to_vec(),
        };

        if payload.len() > MAX_PAYLOAD_LEN {
            return Err(ProtocolError::OversizedFrame {
                len: payload.len(),
                maximum: MAX_PAYLOAD_LEN,
            });
        }
        if payload.len() > self.frame_type().max_payload_len() {
            return Err(ProtocolError::InvalidLength {
                frame_type: self.frame_type().as_u8(),
                len: payload.len(),
            });
        }

        Ok(payload)
    }

    /// Parses a payload using the type nibble from an authenticated header.
    pub fn decode_payload(frame_type: FrameType, payload: &[u8]) -> Result<Self, ProtocolError> {
        if payload.len() > MAX_PAYLOAD_LEN {
            return Err(ProtocolError::OversizedFrame {
                len: payload.len(),
                maximum: MAX_PAYLOAD_LEN,
            });
        }

        match frame_type {
            FrameType::State => Ok(Self::State(StatePayload::decode(payload)?)),
            FrameType::Edges => Ok(Self::Edges(EdgesPayload::decode(payload)?)),
            FrameType::Ack => Ok(Self::Ack(AckPayload::decode(payload)?)),
            FrameType::Ping => Ok(Self::Ping(PingPayload::decode(payload)?)),
            FrameType::Pong => Ok(Self::Pong(PongPayload::decode(payload)?)),
            FrameType::Rumble => Ok(Self::Rumble(RumblePayload::decode(payload)?)),
            FrameType::Disconnect => Ok(Self::Disconnect(DisconnectPayload::decode(payload)?)),
            FrameType::EpochConfirm => {
                Ok(Self::EpochConfirm(EpochConfirmPayload::decode(payload)?))
            }
            FrameType::Error => Ok(Self::Error(ErrorPayload::decode(payload)?)),
            FrameType::ResumeChallenge => Ok(Self::ResumeChallenge(
                ResumeChallengePayload::decode(payload)?,
            )),
            FrameType::ResumeConfirm => {
                Ok(Self::ResumeConfirm(ResumeConfirmPayload::decode(payload)?))
            }
        }
    }
}

fn expect_exact_len(
    frame_type: FrameType,
    payload: &[u8],
    expected: usize,
) -> Result<(), ProtocolError> {
    if payload.len() != expected {
        return Err(ProtocolError::InvalidLength {
            frame_type: frame_type.as_u8(),
            len: payload.len(),
        });
    }
    Ok(())
}

fn read_u16(payload: &[u8], offset: usize) -> Result<u16, ProtocolError> {
    let bytes = payload
        .get(offset..offset + 2)
        .ok_or(ProtocolError::TruncatedFrame {
            len: payload.len(),
            minimum: offset + 2,
        })?;
    Ok(u16::from_le_bytes(bytes.try_into().map_err(|_| {
        ProtocolError::TruncatedFrame {
            len: payload.len(),
            minimum: offset + 2,
        }
    })?))
}

fn read_i16(payload: &[u8], offset: usize) -> Result<i16, ProtocolError> {
    Ok(i16::from_le_bytes(read_u16(payload, offset)?.to_le_bytes()))
}

fn read_u64(payload: &[u8], offset: usize) -> Result<u64, ProtocolError> {
    let bytes = payload
        .get(offset..offset + 8)
        .ok_or(ProtocolError::TruncatedFrame {
            len: payload.len(),
            minimum: offset + 8,
        })?;
    Ok(u64::from_le_bytes(bytes.try_into().map_err(|_| {
        ProtocolError::TruncatedFrame {
            len: payload.len(),
            minimum: offset + 8,
        }
    })?))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_state() -> StatePayload {
        StatePayload {
            latest_edge_id: 7,
            sample_time_us: 123_456,
            buttons: Buttons::A | Buttons::DPAD_UP | Buttons::LEFT_STICK,
            left_trigger: 10,
            right_trigger: 200,
            left_stick: Stick { x: -123, y: 456 },
            right_stick: Stick {
                x: i16::MIN,
                y: i16::MAX,
            },
        }
    }

    #[test]
    fn header_round_trip() {
        let header = Header {
            frame_type: FrameType::State,
            session_tag: 0xA55A,
            seq: 0x0102_0304_0506_0708,
        };
        let encoded = header.encode();
        assert_eq!(encoded.len(), HEADER_LEN);
        assert_eq!(encoded[0], MAGIC);
        assert_eq!(encoded[1], 0x11);
        assert_eq!(Header::decode(&encoded).unwrap(), header);
    }

    #[test]
    fn header_rejects_bad_magic_version_and_type() {
        let mut header = Header {
            frame_type: FrameType::State,
            session_tag: 1,
            seq: 2,
        }
        .encode();

        header[0] = 0;
        assert!(matches!(
            Header::decode(&header),
            Err(ProtocolError::BadMagic(0))
        ));

        let mut header = Header {
            frame_type: FrameType::State,
            session_tag: 1,
            seq: 2,
        }
        .encode();
        header[1] = 0x21;
        assert!(matches!(
            Header::decode(&header),
            Err(ProtocolError::UnsupportedVersion(2))
        ));

        let mut header = Header {
            frame_type: FrameType::State,
            session_tag: 1,
            seq: 2,
        }
        .encode();
        header[1] = 0x1F;
        assert!(matches!(
            Header::decode(&header),
            Err(ProtocolError::UnknownFrameType(15))
        ));
    }

    #[test]
    fn button_bits_are_frozen() {
        assert_eq!(Buttons::A.bits(), 0x0001);
        assert_eq!(Buttons::B.bits(), 0x0002);
        assert_eq!(Buttons::X.bits(), 0x0004);
        assert_eq!(Buttons::Y.bits(), 0x0008);
        assert_eq!(Buttons::LEFT_BUMPER.bits(), 0x0010);
        assert_eq!(Buttons::RIGHT_BUMPER.bits(), 0x0020);
        assert_eq!(Buttons::BACK.bits(), 0x0040);
        assert_eq!(Buttons::START.bits(), 0x0080);
        assert_eq!(Buttons::GUIDE.bits(), 0x0100);
        assert_eq!(Buttons::LEFT_STICK.bits(), 0x0200);
        assert_eq!(Buttons::RIGHT_STICK.bits(), 0x0400);
        assert_eq!(Buttons::DPAD_UP.bits(), 0x0800);
        assert_eq!(Buttons::DPAD_DOWN.bits(), 0x1000);
        assert_eq!(Buttons::DPAD_LEFT.bits(), 0x2000);
        assert_eq!(Buttons::DPAD_RIGHT.bits(), 0x4000);
        assert!(Buttons::from_bits(0x8000).is_err());
    }

    #[test]
    fn state_round_trip_and_exact_length() {
        let state = sample_state();
        let encoded = state.encode();
        assert_eq!(encoded.len(), 28);
        assert_eq!(StatePayload::decode(&encoded).unwrap(), state);
    }

    #[test]
    fn state_rejects_reserved_button_bit() {
        let mut encoded = sample_state().encode();
        encoded[16] = 0x00;
        encoded[17] = 0x80;
        assert!(matches!(
            StatePayload::decode(&encoded),
            Err(ProtocolError::ReservedNonZero { .. })
        ));
    }

    #[test]
    fn state_rejects_wrong_lengths() {
        for length in [0, 27, 29, 56] {
            let payload = vec![0_u8; length];
            assert!(StatePayload::decode(&payload).is_err(), "length {length}");
        }
    }

    #[test]
    fn edges_round_trip() {
        let edges = EdgesPayload {
            entries: vec![
                Edge {
                    edge_id: 1,
                    buttons: Buttons::A,
                    event_time_us: 100,
                },
                Edge {
                    edge_id: 2,
                    buttons: Buttons::neutral(),
                    event_time_us: 200,
                },
            ],
        };
        let encoded = edges.encode().unwrap();
        assert_eq!(encoded.len(), 2 + 2 * 18);
        assert_eq!(EdgesPayload::decode(&encoded).unwrap(), edges);
    }

    #[test]
    fn edges_reject_invalid_batches() {
        let empty = EdgesPayload { entries: vec![] };
        assert!(empty.encode().is_err());

        let duplicate = EdgesPayload {
            entries: vec![
                Edge {
                    edge_id: 1,
                    buttons: Buttons::A,
                    event_time_us: 1,
                },
                Edge {
                    edge_id: 1,
                    buttons: Buttons::B,
                    event_time_us: 2,
                },
            ],
        };
        assert!(duplicate.encode().is_err());

        let mut encoded = vec![0_u8; 2 + 18];
        encoded[0] = 1;
        encoded[1] = 1;
        assert!(matches!(
            EdgesPayload::decode(&encoded),
            Err(ProtocolError::ReservedNonZero { .. })
        ));

        encoded[1] = 0;
        encoded[0] = 0;
        assert!(EdgesPayload::decode(&encoded).is_err());

        encoded[0] = 13;
        encoded.resize(2 + 13 * 18, 0);
        assert!(EdgesPayload::decode(&encoded).is_err());
    }

    #[test]
    fn max_edges_fit_the_frame_budget() {
        let entries = (1..=MAX_EDGES_PER_FRAME as u64)
            .map(|edge_id| Edge {
                edge_id,
                buttons: Buttons::neutral(),
                event_time_us: edge_id,
            })
            .collect();
        let frame = Frame::Edges(EdgesPayload { entries });
        let payload = frame.encode_payload().unwrap();
        assert_eq!(payload.len(), MAX_PAYLOAD_LEN - 10);
        assert_eq!(HEADER_LEN + payload.len() + TAG_LEN, 246);
    }

    #[test]
    fn control_frames_round_trip() {
        let frames = [
            Frame::Ack(AckPayload {
                highest_contiguous_edge_id: 42,
            }),
            Frame::Ping(PingPayload {
                ping_id: 9,
                sent_time_us: 123,
            }),
            Frame::Pong(PongPayload {
                ping_id: 9,
                echo_time_us: 123,
                received_time_us: 130,
                sent_time_us: 131,
            }),
            Frame::Rumble(RumblePayload {
                left: 10,
                right: 20,
                duration_ms: 500,
            }),
            Frame::Disconnect(DisconnectPayload {
                reason: DisconnectReason::PhonePaused,
            }),
            Frame::EpochConfirm(EpochConfirmPayload {
                epoch: 3,
                baseline_edge_id: 0,
                flags: EpochConfirmPayload::FLAG_NEUTRAL_BASELINE,
            }),
            Frame::Error(ErrorPayload { code: 7, detail: 8 }),
            Frame::ResumeChallenge(ResumeChallengePayload {
                epoch: 4,
                challenge: [5; 16],
            }),
            Frame::ResumeConfirm(ResumeConfirmPayload {
                epoch: 4,
                challenge_echo: [6; 16],
                mac: [7; 32],
            }),
        ];

        for frame in frames {
            let payload = frame.encode_payload().unwrap();
            let decoded = Frame::decode_payload(frame.frame_type(), &payload).unwrap();
            assert_eq!(decoded, frame);
        }
    }

    #[test]
    fn rumble_duration_is_bounded() {
        let rumble = RumblePayload {
            left: 1,
            right: 1,
            duration_ms: MAX_RUMBLE_MS + 1,
        };
        assert!(rumble.encode().is_err());

        let mut payload = rumble.encode().unwrap_or([0; 4]);
        payload[0] = 1;
        payload[1] = 1;
        payload[2..4].copy_from_slice(&(MAX_RUMBLE_MS + 1).to_le_bytes());
        assert!(RumblePayload::decode(&payload).is_err());
    }

    #[test]
    fn epoch_confirm_requires_neutral_baseline() {
        let invalid = EpochConfirmPayload {
            epoch: 1,
            baseline_edge_id: 3,
            flags: EpochConfirmPayload::FLAG_NEUTRAL_BASELINE,
        };
        assert!(invalid.encode().is_err());

        let mut payload = EpochConfirmPayload {
            epoch: 1,
            baseline_edge_id: 0,
            flags: EpochConfirmPayload::FLAG_NEUTRAL_BASELINE,
        }
        .encode()
        .unwrap();
        payload[14] = 1;
        assert!(matches!(
            EpochConfirmPayload::decode(&payload),
            Err(ProtocolError::ReservedNonZero { .. })
        ));
    }

    #[test]
    fn oversized_payloads_are_rejected_before_parsing() {
        let payload = vec![0_u8; MAX_PAYLOAD_LEN + 1];
        assert!(matches!(
            Frame::decode_payload(FrameType::State, &payload),
            Err(ProtocolError::OversizedFrame { .. })
        ));
    }

    #[test]
    fn random_bytes_never_panic() {
        let mut state = 0x1234_5678_9ABC_DEF0_u64;
        for length in 0..=320 {
            let mut payload = vec![0_u8; length];
            for byte in &mut payload {
                state ^= state << 13;
                state ^= state >> 7;
                state ^= state << 17;
                *byte = state as u8;
            }

            for frame_type in FrameType::ALL {
                let _ = Frame::decode_payload(frame_type, &payload);
            }
            let _ = Header::decode(&payload);
        }
    }
}
