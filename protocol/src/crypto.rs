//! Session key schedule, authenticated framing, and replay protection.
//!
//! The pairing layer must produce a 32-byte root secret and a 128-bit session
//! ID. This module turns those into independent directional traffic keys. It
//! does not implement the PAKE or the pairing handshake.

use chacha20poly1305::aead::{Aead, KeyInit, Payload as AeadPayload};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use hkdf::Hkdf;
use sha2::Sha256;
use zeroize::Zeroizing;

use crate::error::ProtocolError;
use crate::frame::{Frame, FrameType, HEADER_LEN, Header, MAX_FRAME_LEN, MAX_PAYLOAD_LEN, TAG_LEN};

/// Bytes in a traffic key.
pub const KEY_LEN: usize = 32;
/// Bytes in a nonce prefix.
pub const NONCE_PREFIX_LEN: usize = 4;
/// The sender must rekey before this sequence number.
///
/// The wire counter is 64 bits, but rekeying at 2^48 leaves an enormous margin
/// and keeps the nonce prefix + counter construction unambiguous.
pub const MAX_SEQUENCE_BEFORE_REKEY: u64 = 1 << 48;

const TRAFFIC_LABEL: &[u8] = b"padlink/v1/traffic";

/// Direction of a directional traffic key.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum Direction {
    PhoneToDesktop = 1,
    DesktopToPhone = 2,
}

impl Direction {
    /// The opposite key direction.
    pub const fn opposite(self) -> Self {
        match self {
            Self::PhoneToDesktop => Self::DesktopToPhone,
            Self::DesktopToPhone => Self::PhoneToDesktop,
        }
    }
}

/// Transport a traffic key is scoped to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum Transport {
    Udp = 1,
    Tcp = 2,
}

/// Everything that separates one traffic key from another.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct KeyDomain {
    pub direction: Direction,
    pub transport: Transport,
    pub epoch: u32,
}

impl KeyDomain {
    pub const fn new(direction: Direction, transport: Transport, epoch: u32) -> Self {
        Self {
            direction,
            transport,
            epoch,
        }
    }
}

/// A full random 128-bit session identity.
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct SessionId([u8; 16]);

impl SessionId {
    /// Generates a session ID from the operating system random source.
    pub fn generate() -> Result<Self, ProtocolError> {
        let mut bytes = [0_u8; 16];
        getrandom::fill(&mut bytes).map_err(|_| ProtocolError::RandomUnavailable)?;
        Ok(Self(bytes))
    }

    /// Wraps an existing 128-bit value, for example from a completed PAKE.
    pub const fn from_bytes(bytes: [u8; 16]) -> Self {
        Self(bytes)
    }

    /// Raw session identity bytes.
    pub const fn as_bytes(&self) -> &[u8; 16] {
        &self.0
    }

    /// Two-byte routing hint carried in clear headers.
    ///
    /// This is not an authenticator; AEAD and the directional key provide
    /// authentication.
    pub const fn tag(&self) -> u16 {
        u16::from_le_bytes([self.0[0], self.0[1]])
    }
}

impl std::fmt::Debug for SessionId {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("SessionId(")?;
        for byte in self.0 {
            write!(formatter, "{byte:02x}")?;
        }
        formatter.write_str(")")
    }
}

/// A session root secret produced by the pairing layer.
pub struct SessionSecret(Zeroizing<[u8; KEY_LEN]>);

impl SessionSecret {
    /// Generates a root secret from the operating system random source.
    pub fn generate() -> Result<Self, ProtocolError> {
        let mut bytes = [0_u8; KEY_LEN];
        getrandom::fill(&mut bytes).map_err(|_| ProtocolError::RandomUnavailable)?;
        Ok(Self(Zeroizing::new(bytes)))
    }

    /// Wraps a secret from a completed PAKE.
    pub fn from_bytes(bytes: [u8; KEY_LEN]) -> Self {
        Self(Zeroizing::new(bytes))
    }

    fn expose(&self) -> &[u8; KEY_LEN] {
        &self.0
    }
}

impl std::fmt::Debug for SessionSecret {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("SessionSecret([redacted])")
    }
}

/// One directional, transport-scoped traffic key with its monotonic counter.
pub struct TrafficKey {
    key: Zeroizing<[u8; KEY_LEN]>,
    nonce_prefix: [u8; NONCE_PREFIX_LEN],
    session_tag: u16,
    domain: KeyDomain,
    next_seq: u64,
}

impl TrafficKey {
    /// Derives a key from the session root and ID.
    pub fn derive(
        root: &SessionSecret,
        session_id: SessionId,
        domain: KeyDomain,
    ) -> Result<Self, ProtocolError> {
        let mut salt = Vec::with_capacity(10 + 16);
        salt.extend_from_slice(b"padlink/v1");
        salt.extend_from_slice(session_id.as_bytes());

        let mut info = Vec::with_capacity(TRAFFIC_LABEL.len() + 8);
        info.extend_from_slice(TRAFFIC_LABEL);
        info.push(domain.direction as u8);
        info.push(domain.transport as u8);
        info.extend_from_slice(&domain.epoch.to_le_bytes());

        let mut output = [0_u8; KEY_LEN + NONCE_PREFIX_LEN];
        let hkdf = Hkdf::<Sha256>::new(Some(&salt), root.expose());
        hkdf.expand(&info, &mut output)
            .map_err(|_| ProtocolError::Unavailable("HKDF expansion failed"))?;

        let mut key = [0_u8; KEY_LEN];
        key.copy_from_slice(&output[..KEY_LEN]);
        let mut nonce_prefix = [0_u8; NONCE_PREFIX_LEN];
        nonce_prefix.copy_from_slice(&output[KEY_LEN..]);

        Ok(Self {
            key: Zeroizing::new(key),
            nonce_prefix,
            session_tag: session_id.tag(),
            domain,
            next_seq: 0,
        })
    }

    /// The domain this key is scoped to.
    pub const fn domain(&self) -> KeyDomain {
        self.domain
    }

    /// The routing hint for this session.
    pub const fn session_tag(&self) -> u16 {
        self.session_tag
    }

    /// The next counter value that would be used.
    pub const fn next_sequence(&self) -> u64 {
        self.next_seq
    }

    /// Encrypts a frame payload and returns `header || ciphertext || tag`.
    pub fn seal_frame(&mut self, frame: &Frame) -> Result<Vec<u8>, ProtocolError> {
        let payload = frame.encode_payload()?;
        if payload.len() > MAX_PAYLOAD_LEN {
            return Err(ProtocolError::OversizedFrame {
                len: payload.len(),
                maximum: MAX_PAYLOAD_LEN,
            });
        }
        if self.next_seq >= MAX_SEQUENCE_BEFORE_REKEY {
            return Err(ProtocolError::SequenceExhausted);
        }

        let header = Header {
            frame_type: frame.frame_type(),
            session_tag: self.session_tag,
            seq: self.next_seq,
        };
        let header_bytes = header.encode();
        let ciphertext = self.encrypt(&header_bytes, &payload)?;
        let mut frame_bytes = Vec::with_capacity(HEADER_LEN + ciphertext.len());
        frame_bytes.extend_from_slice(&header_bytes);
        frame_bytes.extend_from_slice(&ciphertext);
        self.next_seq += 1;
        Ok(frame_bytes)
    }

    /// Authenticates and decrypts one frame.
    ///
    /// The replay window is updated only after AEAD verification succeeds.
    /// Invalid or replayed traffic never advances session state.
    pub fn open_frame(
        &self,
        bytes: &[u8],
        replay: &mut ReplayWindow,
    ) -> Result<OpenedFrame, ProtocolError> {
        if bytes.len() < HEADER_LEN + TAG_LEN {
            return Err(ProtocolError::TruncatedFrame {
                len: bytes.len(),
                minimum: HEADER_LEN + TAG_LEN,
            });
        }
        if bytes.len() > MAX_FRAME_LEN {
            return Err(ProtocolError::OversizedFrame {
                len: bytes.len(),
                maximum: MAX_FRAME_LEN,
            });
        }

        let header = Header::decode(&bytes[..HEADER_LEN])?;
        if header.session_tag != self.session_tag {
            return Err(ProtocolError::SessionTagMismatch);
        }
        if header.seq >= MAX_SEQUENCE_BEFORE_REKEY {
            return Err(ProtocolError::SequenceExhausted);
        }

        let plaintext = self.decrypt(&bytes[..HEADER_LEN], &bytes[HEADER_LEN..], header.seq)?;
        if plaintext.len() > MAX_PAYLOAD_LEN {
            return Err(ProtocolError::OversizedFrame {
                len: plaintext.len(),
                maximum: MAX_PAYLOAD_LEN,
            });
        }

        if !replay.accept(header.seq) {
            return Err(ProtocolError::ReplayedSequence { seq: header.seq });
        }

        let frame = Frame::decode_payload(header.frame_type, &plaintext)?;
        Ok(OpenedFrame { header, frame })
    }

    fn encrypt(&self, aad: &[u8], payload: &[u8]) -> Result<Vec<u8>, ProtocolError> {
        let cipher = ChaCha20Poly1305::new(Key::from_slice(&self.key[..]));
        let nonce = self.nonce_for(self.next_seq);
        cipher
            .encrypt(Nonce::from_slice(&nonce), AeadPayload { msg: payload, aad })
            .map_err(|_| ProtocolError::AuthenticationFailed)
    }

    fn decrypt(&self, aad: &[u8], ciphertext: &[u8], seq: u64) -> Result<Vec<u8>, ProtocolError> {
        let cipher = ChaCha20Poly1305::new(Key::from_slice(&self.key[..]));
        let nonce = self.nonce_for(seq);
        cipher
            .decrypt(
                Nonce::from_slice(&nonce),
                AeadPayload {
                    msg: ciphertext,
                    aad,
                },
            )
            .map_err(|_| ProtocolError::AuthenticationFailed)
    }

    fn nonce_for(&self, seq: u64) -> [u8; 12] {
        let mut nonce = [0_u8; 12];
        nonce[..NONCE_PREFIX_LEN].copy_from_slice(&self.nonce_prefix);
        nonce[NONCE_PREFIX_LEN..].copy_from_slice(&seq.to_le_bytes());
        nonce
    }
}

impl std::fmt::Debug for TrafficKey {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("TrafficKey")
            .field("domain", &self.domain)
            .field("session_tag", &self.session_tag)
            .field("next_seq", &self.next_seq)
            .finish_non_exhaustive()
    }
}

/// A successfully authenticated frame.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpenedFrame {
    pub header: Header,
    pub frame: Frame,
}

/// Sliding replay window for one directional key domain.
///
/// A window of 64 packets tolerates normal UDP reordering while rejecting
/// duplicates and very old packets. Packets older than the window are dropped.
#[derive(Debug, Clone, Default)]
pub struct ReplayWindow {
    highest: u64,
    bitmap: u64,
    initialized: bool,
}

impl ReplayWindow {
    /// Creates an empty window.
    pub const fn new() -> Self {
        Self {
            highest: 0,
            bitmap: 0,
            initialized: false,
        }
    }

    /// Attempts to accept a packet counter.
    ///
    /// Returns `true` exactly once per counter. Call this only after the packet
    /// authenticated successfully.
    pub fn accept(&mut self, seq: u64) -> bool {
        if !self.initialized {
            self.initialized = true;
            self.highest = seq;
            self.bitmap = 1;
            return true;
        }

        if seq > self.highest {
            let shift = seq - self.highest;
            self.bitmap = if shift >= 64 {
                1
            } else {
                (self.bitmap << shift) | 1
            };
            self.highest = seq;
            return true;
        }

        let distance = self.highest - seq;
        if distance >= 64 {
            return false;
        }

        let mask = 1_u64 << distance;
        if self.bitmap & mask != 0 {
            return false;
        }
        self.bitmap |= mask;
        true
    }
}

/// Verifies that a frame has the fixed authenticated-envelope shape.
pub fn validate_frame_len(frame_type: FrameType, bytes: &[u8]) -> Result<(), ProtocolError> {
    if bytes.len() < HEADER_LEN + TAG_LEN {
        return Err(ProtocolError::TruncatedFrame {
            len: bytes.len(),
            minimum: HEADER_LEN + TAG_LEN,
        });
    }
    if bytes.len() > MAX_FRAME_LEN {
        return Err(ProtocolError::OversizedFrame {
            len: bytes.len(),
            maximum: MAX_FRAME_LEN,
        });
    }
    if bytes.len() - HEADER_LEN - TAG_LEN > frame_type.max_payload_len() {
        return Err(ProtocolError::InvalidLength {
            frame_type: frame_type.as_u8(),
            len: bytes.len(),
        });
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::frame::{
        AckPayload, Buttons, EdgesPayload, Header, RumblePayload, StatePayload, Stick,
    };
    use crate::{MAGIC, WIRE_VERSION};

    fn fixture() -> (SessionSecret, SessionId, KeyDomain) {
        (
            SessionSecret::from_bytes([0x11; KEY_LEN]),
            SessionId::from_bytes([0x22; 16]),
            KeyDomain::new(Direction::PhoneToDesktop, Transport::Udp, 1),
        )
    }

    fn state_frame() -> Frame {
        Frame::State(StatePayload {
            latest_edge_id: 5,
            sample_time_us: 1_000_000,
            buttons: Buttons::A | Buttons::START,
            left_trigger: 12,
            right_trigger: 200,
            left_stick: Stick { x: -100, y: 200 },
            right_stick: Stick { x: 300, y: -400 },
        })
    }

    #[test]
    fn rfc8439_aead_vector() {
        let key = hex::decode("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
            .unwrap();
        let nonce = hex::decode("070000004041424344454647").unwrap();
        let aad = hex::decode("50515253c0c1c2c3c4c5c6c7").unwrap();
        let plaintext = b"Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.";
        let expected = hex::decode(concat!(
            "d31a8d34648e60db7b86afbc53ef7ec2",
            "a4aded51296e08fea9e2b5a736ee62d6",
            "3dbea45e8ca9671282fafb69da92728b",
            "1a71de0a9e060b2905d6a5b67ecd3b36",
            "92ddbd7f2d778b8c9803aee328091b58",
            "fab324e4fad675945585808b4831d7bc",
            "3ff4def08e4b7a9de576d26586cec64b",
            "6116",
            "1ae10b594f09e26a7e902ecbd0600691"
        ))
        .unwrap();

        let cipher = ChaCha20Poly1305::new(Key::from_slice(&key));
        let ciphertext = cipher
            .encrypt(
                Nonce::from_slice(&nonce),
                AeadPayload {
                    msg: plaintext,
                    aad: &aad,
                },
            )
            .unwrap();
        assert_eq!(ciphertext, expected);
    }

    #[test]
    fn directional_transports_and_epochs_are_domain_separated() {
        let (root, session, _) = fixture();
        let mut materials = Vec::new();
        for direction in [Direction::PhoneToDesktop, Direction::DesktopToPhone] {
            for transport in [Transport::Udp, Transport::Tcp] {
                for epoch in [1, 2] {
                    materials.push(
                        TrafficKey::derive(
                            &root,
                            session,
                            KeyDomain::new(direction, transport, epoch),
                        )
                        .unwrap(),
                    );
                }
            }
        }

        for left in 0..materials.len() {
            for right in left + 1..materials.len() {
                let left_bytes = materials[left].key.to_vec();
                let right_bytes = materials[right].key.to_vec();
                assert_ne!(left_bytes, right_bytes);
                assert_ne!(materials[left].nonce_prefix, materials[right].nonce_prefix);
            }
        }
    }

    #[test]
    fn state_frame_is_exactly_56_bytes() {
        let (root, session, domain) = fixture();
        let mut key = TrafficKey::derive(&root, session, domain).unwrap();
        let sealed = key.seal_frame(&state_frame()).unwrap();
        assert_eq!(sealed.len(), 56);
        assert_eq!(key.next_sequence(), 1);
    }

    #[test]
    fn seal_open_round_trip_for_every_frame_shape() {
        let (root, session, domain) = fixture();
        let mut sender = TrafficKey::derive(&root, session, domain).unwrap();
        let receiver = TrafficKey::derive(&root, session, domain).unwrap();
        let mut replay = ReplayWindow::new();

        let frames = [
            state_frame(),
            Frame::Edges(EdgesPayload {
                entries: vec![crate::frame::Edge {
                    edge_id: 1,
                    buttons: Buttons::A,
                    event_time_us: 10,
                }],
            }),
            Frame::Ack(AckPayload {
                highest_contiguous_edge_id: 1,
            }),
            Frame::Rumble(RumblePayload {
                left: 1,
                right: 2,
                duration_ms: 100,
            }),
        ];

        for frame in frames {
            let sealed = sender.seal_frame(&frame).unwrap();
            let opened = receiver.open_frame(&sealed, &mut replay).unwrap();
            assert_eq!(opened.frame, frame);
        }
    }

    #[test]
    fn tampered_header_payload_or_tag_is_rejected() {
        let (root, session, domain) = fixture();
        let mut sender = TrafficKey::derive(&root, session, domain).unwrap();
        let receiver = TrafficKey::derive(&root, session, domain).unwrap();

        let sealed = sender.seal_frame(&state_frame()).unwrap();

        for index in [0, 1, 2, 3, 4, 5, 11, 12, 30, sealed.len() - 1] {
            let mut tampered = sealed.clone();
            tampered[index] ^= 0x01;
            let mut replay = ReplayWindow::new();
            assert!(
                receiver.open_frame(&tampered, &mut replay).is_err(),
                "tamper at {index}"
            );
        }
    }

    #[test]
    fn wrong_key_and_session_tag_are_rejected() {
        let (root, session, domain) = fixture();
        let mut sender = TrafficKey::derive(&root, session, domain).unwrap();
        let sealed = sender.seal_frame(&state_frame()).unwrap();

        let other_root = SessionSecret::from_bytes([0x33; KEY_LEN]);
        let other = TrafficKey::derive(&other_root, session, domain).unwrap();
        let mut replay = ReplayWindow::new();
        assert_eq!(
            other.open_frame(&sealed, &mut replay),
            Err(ProtocolError::AuthenticationFailed)
        );

        let other_session = SessionId::from_bytes([0x44; 16]);
        let other_tag = TrafficKey::derive(&root, other_session, domain).unwrap();
        let mut replay = ReplayWindow::new();
        assert_eq!(
            other_tag.open_frame(&sealed, &mut replay),
            Err(ProtocolError::SessionTagMismatch)
        );
    }

    #[test]
    fn replay_and_reordering_rules() {
        let (root, session, domain) = fixture();
        let mut sender = TrafficKey::derive(&root, session, domain).unwrap();
        let receiver = TrafficKey::derive(&root, session, domain).unwrap();
        let mut replay = ReplayWindow::new();

        let first = sender.seal_frame(&state_frame()).unwrap();
        let second = sender.seal_frame(&state_frame()).unwrap();
        let third = sender.seal_frame(&state_frame()).unwrap();

        assert!(receiver.open_frame(&third, &mut replay).is_ok());
        assert!(receiver.open_frame(&first, &mut replay).is_ok());
        assert_eq!(
            receiver.open_frame(&first, &mut replay),
            Err(ProtocolError::ReplayedSequence { seq: 0 })
        );
        assert!(receiver.open_frame(&second, &mut replay).is_ok());
        assert_eq!(
            receiver.open_frame(&second, &mut replay),
            Err(ProtocolError::ReplayedSequence { seq: 1 })
        );
    }

    #[test]
    fn replay_window_boundaries() {
        let mut window = ReplayWindow::new();
        assert!(window.accept(1));
        assert!(window.accept(3));
        assert!(window.accept(2));
        assert!(!window.accept(2));
        assert!(window.accept(0));
        assert!(!window.accept(0));
        assert!(window.accept(100));
        assert!(!window.accept(36));
        assert!(window.accept(37));
        assert!(!window.accept(37));
        assert!(window.accept(u64::MAX));
        assert!(window.accept(u64::MAX - 1));
        assert!(!window.accept(u64::MAX));
    }

    #[test]
    fn counter_exhaustion_requires_rekey() {
        let (root, session, domain) = fixture();
        let mut key = TrafficKey::derive(&root, session, domain).unwrap();
        key.next_seq = MAX_SEQUENCE_BEFORE_REKEY;
        assert_eq!(
            key.seal_frame(&state_frame()),
            Err(ProtocolError::SequenceExhausted)
        );
        assert_eq!(key.next_sequence(), MAX_SEQUENCE_BEFORE_REKEY);
    }

    #[test]
    fn receiver_rejects_counters_beyond_the_rekey_threshold() {
        let (root, session, domain) = fixture();
        let receiver = TrafficKey::derive(&root, session, domain).unwrap();
        let header = Header {
            frame_type: FrameType::State,
            session_tag: session.tag(),
            seq: MAX_SEQUENCE_BEFORE_REKEY,
        }
        .encode();
        let mut bytes = Vec::from(header);
        bytes.extend_from_slice(&[0_u8; TAG_LEN]);

        let mut replay = ReplayWindow::new();
        assert_eq!(
            receiver.open_frame(&bytes, &mut replay),
            Err(ProtocolError::SequenceExhausted)
        );
    }

    #[test]
    fn oversized_frames_are_rejected() {
        let (root, session, domain) = fixture();
        let receiver = TrafficKey::derive(&root, session, domain).unwrap();
        let mut replay = ReplayWindow::new();
        let mut bytes = vec![0_u8; MAX_FRAME_LEN + 1];
        bytes[0] = MAGIC;
        bytes[1] = (WIRE_VERSION << 4) | FrameType::State.as_u8();
        assert!(matches!(
            receiver.open_frame(&bytes, &mut replay),
            Err(ProtocolError::OversizedFrame { .. })
        ));
    }

    #[test]
    fn truncated_frames_are_rejected() {
        let (root, session, domain) = fixture();
        let receiver = TrafficKey::derive(&root, session, domain).unwrap();
        let mut replay = ReplayWindow::new();
        for length in 0..HEADER_LEN + TAG_LEN {
            assert!(
                receiver
                    .open_frame(&vec![0_u8; length], &mut replay)
                    .is_err()
            );
        }
    }

    #[test]
    fn golden_state_frame_vector() {
        let root = SessionSecret::from_bytes([
            0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D,
            0x0E, 0x0F, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B,
            0x1C, 0x1D, 0x1E, 0x1F,
        ]);
        let session = SessionId::from_bytes([
            0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xAB, 0xAC, 0xAD,
            0xAE, 0xAF,
        ]);
        let mut key = TrafficKey::derive(
            &root,
            session,
            KeyDomain::new(Direction::PhoneToDesktop, Transport::Udp, 1),
        )
        .unwrap();

        let sealed = key
            .seal_frame(&Frame::State(StatePayload {
                latest_edge_id: 0,
                sample_time_us: 0,
                buttons: Buttons::A | Buttons::DPAD_UP,
                left_trigger: 0,
                right_trigger: 255,
                left_stick: Stick {
                    x: -32768,
                    y: 32767,
                },
                right_stick: Stick::NEUTRAL,
            }))
            .unwrap();

        // Filled from the first reviewed implementation run; see SPEC.md.
        assert_eq!(
            hex::encode(&sealed),
            "5011a0a10000000000000000d29058eb1bef0edde72c3a87714c0a7089382e2008c707fb383ade991b90b688cb5a088577b119e9cfa33684"
        );
    }
}
