//! Phone-wide pairing admission and consent ownership, independent of UI/OS.
//!
//! Keep one host for the app process, including across listener stop/start.
//! Admit accepted sockets using the OS peer IP before reading/parsing requests.
//! Poll deadlines without traffic, and close the socket when a method fails.
//! A connection loss cancels its token; another socket requires fresh consent
//! and consumes the same phone-wide request budget. No token is auto-issued.

use std::net::IpAddr;

use crate::ProtocolError;

use super::transport::FRAME_PROGRESS_TIMEOUT_MS;
use super::{PairedSession, PairingMessage, PairingRequest, PhoneHandshake};

pub const REQUEST_WINDOW_MS: u64 = 60_000;
pub const MAX_REQUESTS_PER_WINDOW: usize = 5;
/// An unanswered Allow/Deny prompt does not occupy the listener indefinitely.
pub const CONSENT_TIMEOUT_MS: u64 = 30_000;

/// Process-local socket identity, never supplied by an unauthenticated peer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ConnectionId(u64);
impl ConnectionId {
    pub const fn value(self) -> u64 {
        self.0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HostState {
    Idle,
    ReadingRequest,
    AwaitingConsent,
    AwaitingCode,
    AwaitingConfirmation,
    SendingReady,
    Paired,
}

/// Transport work to perform after a successfully handled message.
/// The caller queues the reply once; short writes reuse the same sealed bytes.
pub enum HostEvent {
    ConsentRequested,
    Reply(PairingMessage),
    /// A complete authenticated TCP frame, including its prefix.
    Ready(Vec<u8>),
    /// Peer Abort: close the socket; no response or session exists.
    Cancelled,
    RetryReady,
}

impl std::fmt::Debug for HostEvent {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::ConsentRequested => f.write_str("ConsentRequested"),
            Self::Reply(message) => f.debug_tuple("Reply").field(message).finish(),
            Self::Ready(_) => f.write_str("Ready([frame redacted])"),
            Self::Cancelled => f.write_str("Cancelled"),
            Self::RetryReady => f.write_str("RetryReady"),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HostError {
    Protocol(ProtocolError),
    RateLimited { retry_after_ms: u64 },
    Busy,
    StaleConnection,
    InvalidState,
    DeadlineExpired,
    ClockRegression,
    TimeOverflow,
    ConnectionIdsExhausted,
}

impl std::fmt::Display for HostError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Protocol(error) => error.fmt(f),
            Self::RateLimited { retry_after_ms } => {
                write!(
                    f,
                    "pairing request limit reached; retry in {retry_after_ms} ms"
                )
            }
            Self::Busy => f.write_str("phone already has a pending or paired connection"),
            Self::StaleConnection => f.write_str("pairing connection is no longer current"),
            Self::InvalidState => f.write_str("pairing action is invalid in this state"),
            Self::DeadlineExpired => f.write_str("pairing connection deadline expired"),
            Self::ClockRegression => f.write_str("monotonic pairing clock moved backwards"),
            Self::TimeOverflow => f.write_str("pairing deadline overflow"),
            Self::ConnectionIdsExhausted => f.write_str("pairing connection IDs exhausted"),
        }
    }
}

impl std::error::Error for HostError {}

impl From<ProtocolError> for HostError {
    fn from(value: ProtocolError) -> Self {
        Self::Protocol(value)
    }
}

#[derive(Clone, Copy)]
struct RequestRecord {
    source: IpAddr,
    at_ms: u64,
}

/// Both limits use the same fixed five-record rolling window. The phone-wide
/// limit also bounds the per-source storage, even under source-address churn.
struct RequestLimiter {
    records: [Option<RequestRecord>; MAX_REQUESTS_PER_WINDOW],
}

impl RequestLimiter {
    const fn new() -> Self {
        Self {
            records: [None; MAX_REQUESTS_PER_WINDOW],
        }
    }

    fn admit(&mut self, source: IpAddr, now_ms: u64) -> Result<(), HostError> {
        let source = match source {
            IpAddr::V6(address) => address.to_ipv4_mapped().map(IpAddr::V4).unwrap_or(source),
            _ => source,
        };
        for record in &mut self.records {
            if record.is_some_and(|entry| now_ms.saturating_sub(entry.at_ms) >= REQUEST_WINDOW_MS) {
                *record = None;
            }
        }
        let global_count = self.records.iter().flatten().count();
        let source_count = self
            .records
            .iter()
            .flatten()
            .filter(|entry| entry.source == source)
            .count();
        if global_count >= MAX_REQUESTS_PER_WINDOW || source_count >= MAX_REQUESTS_PER_WINDOW {
            let oldest = self.records.iter().flatten().map(|entry| entry.at_ms).min();
            return Err(HostError::RateLimited {
                retry_after_ms: REQUEST_WINDOW_MS - now_ms.saturating_sub(oldest.unwrap_or(now_ms)),
            });
        }
        // A free slot exists because the fixed global count was checked.
        if let Some(slot) = self.records.iter_mut().find(|slot| slot.is_none()) {
            *slot = Some(RequestRecord {
                source,
                at_ms: now_ms,
            });
        }
        Ok(())
    }
}

enum PendingStage {
    ReadingRequest,
    AwaitingConsent(PairingRequest),
    Allowed {
        handshake: Box<PhoneHandshake>,
        awaiting_confirmation: bool,
    },
    Ready(Box<PairedSession>),
}

struct Pending {
    id: ConnectionId,
    request_id: Option<[u8; 16]>,
    deadline_ms: u64,
    stage: PendingStage,
}

struct Active {
    id: ConnectionId,
    session: Option<Box<PairedSession>>,
}

/// One pending connection and one exclusive confirmed session slot. Session
/// access remains unavailable until the ready frame has been fully written.
/// This is pairing ownership, not a controller backend or input authorization.
pub struct PhonePairingHost {
    limiter: RequestLimiter,
    next_id: u64,
    last_now_ms: u64,
    pending: Option<Pending>,
    active: Option<Active>,
}

impl PhonePairingHost {
    pub const fn new(now_ms: u64) -> Self {
        Self {
            limiter: RequestLimiter::new(),
            next_id: 0,
            last_now_ms: now_ms,
            pending: None,
            active: None,
        }
    }

    pub fn state(&self) -> HostState {
        if self.active.is_some() {
            return HostState::Paired;
        }
        match self.pending.as_ref().map(|pending| &pending.stage) {
            None => HostState::Idle,
            Some(PendingStage::ReadingRequest) => HostState::ReadingRequest,
            Some(PendingStage::AwaitingConsent(_)) => HostState::AwaitingConsent,
            Some(PendingStage::Allowed {
                awaiting_confirmation: false,
                ..
            }) => HostState::AwaitingCode,
            Some(PendingStage::Allowed {
                awaiting_confirmation: true,
                ..
            }) => HostState::AwaitingConfirmation,
            Some(PendingStage::Ready(_)) => HostState::SendingReady,
        }
    }

    pub fn deadline_ms(&self) -> Option<u64> {
        self.pending.as_ref().map(|pending| pending.deadline_ms)
    }

    /// Counts socket arrivals before parsing. Busy, malformed, denied, expired,
    /// and disconnected requests do not refund their admission. Source ports
    /// and peer-supplied labels/request IDs never key the limiter.
    pub fn begin_connection(
        &mut self,
        source: IpAddr,
        now_ms: u64,
    ) -> Result<ConnectionId, HostError> {
        // Do not silently replace an expired socket: poll_deadline returns its
        // ID so the transport can close it before admitting another one.
        self.check_clock(now_ms)?;
        self.limiter.admit(source, now_ms)?;
        if self.pending.is_some() || self.active.is_some() {
            return Err(HostError::Busy);
        }
        let next_id = self
            .next_id
            .checked_add(1)
            .ok_or(HostError::ConnectionIdsExhausted)?;
        let deadline_ms = deadline(now_ms, FRAME_PROGRESS_TIMEOUT_MS)?;
        self.next_id = next_id;
        let id = ConnectionId(next_id);
        self.pending = Some(Pending {
            id,
            request_id: None,
            deadline_ms,
            stage: PendingStage::ReadingRequest,
        });
        Ok(id)
    }

    /// Display this label/address as unverified. This getter never issues or
    /// copies a token. UI/transport timers must call poll_deadline separately.
    pub fn consent_request(&self, id: ConnectionId) -> Option<&PairingRequest> {
        let pending = self.pending.as_ref().filter(|pending| pending.id == id)?;
        match &pending.stage {
            PendingStage::AwaitingConsent(request) => Some(request),
            _ => None,
        }
    }

    /// Call only for the user's real Allow action on this exact prompt ID.
    pub fn allow(&mut self, id: ConnectionId, now_ms: u64) -> Result<PairingMessage, HostError> {
        self.check_pending(id, now_ms)?;
        let mut pending = self.pending.take().ok_or(HostError::StaleConnection)?;
        let PendingStage::AwaitingConsent(request) = &pending.stage else {
            self.pending = Some(pending);
            return Err(HostError::InvalidState);
        };
        let handshake = PhoneHandshake::consent(request, now_ms)?;
        let accept = handshake.accept();
        pending.deadline_ms = handshake.expires_at_ms();
        pending.stage = PendingStage::Allowed {
            handshake: Box::new(handshake),
            awaiting_confirmation: false,
        };
        self.pending = Some(pending);
        Ok(accept)
    }

    /// Denying a prompt removes it without ever generating a token.
    /// Queue the Abort if writable, then close the rejected socket.
    pub fn deny(&mut self, id: ConnectionId, now_ms: u64) -> Result<PairingMessage, HostError> {
        self.check_pending(id, now_ms)?;
        let pending = self.pending.as_ref().ok_or(HostError::StaleConnection)?;
        if !matches!(pending.stage, PendingStage::AwaitingConsent(_)) {
            return Err(HostError::InvalidState);
        }
        let request_id = pending.request_id.ok_or(HostError::InvalidState)?;
        self.pending = None;
        Ok(PairingMessage::Abort {
            request_id,
            reason: 1,
        })
    }

    /// UI-only access. Never log/persist the returned code or copy it into QR.
    pub fn display_code(&mut self, id: ConnectionId, now_ms: u64) -> Result<&str, HostError> {
        self.check_pending(id, now_ms)?;
        let pending = self.pending.as_mut().ok_or(HostError::StaleConnection)?;
        match &mut pending.stage {
            PendingStage::Allowed { handshake, .. } => Ok(handshake.display_code(now_ms)?),
            _ => Err(HostError::InvalidState),
        }
    }

    pub fn attempts_remaining(&self, id: ConnectionId) -> Option<u8> {
        let pending = self.pending.as_ref().filter(|pending| pending.id == id)?;
        match &pending.stage {
            PendingStage::Allowed { handshake, .. } => Some(handshake.attempts_remaining()),
            _ => None,
        }
    }

    /// Handles one decoded message. Wire/PAKE/state errors erase this pending
    /// connection rather than retaining an ambiguous exchange. Another valid
    /// PakeA can retry a wrong code on the same socket, within the same token
    /// and three-attempt budget. A stalled confirmation cancels the connection.
    pub fn receive(
        &mut self,
        id: ConnectionId,
        message: &PairingMessage,
        now_ms: u64,
    ) -> Result<HostEvent, HostError> {
        self.check_pending(id, now_ms)?;
        let mut pending = self.pending.take().ok_or(HostError::StaleConnection)?;
        if let Some(request_id) = pending.request_id {
            if message.request_id() != &request_id {
                return Err(ProtocolError::PairingRequestMismatch.into());
            }
            if matches!(message, PairingMessage::Abort { .. }) {
                return Ok(HostEvent::Cancelled);
            }
        }
        let event = match (&mut pending.stage, message) {
            (
                PendingStage::Allowed {
                    handshake,
                    awaiting_confirmation,
                },
                PairingMessage::Retry { .. },
            ) if *awaiting_confirmation => {
                handshake.fail_attempt();
                handshake.check_live(now_ms)?;
                *awaiting_confirmation = false;
                pending.deadline_ms = handshake.expires_at_ms();
                HostEvent::RetryReady
            }
            (PendingStage::ReadingRequest, PairingMessage::Request(request)) => {
                request.validate()?;
                pending.request_id = Some(request.request_id);
                pending.deadline_ms = deadline(now_ms, CONSENT_TIMEOUT_MS)?;
                pending.stage = PendingStage::AwaitingConsent(request.clone());
                HostEvent::ConsentRequested
            }
            (
                PendingStage::Allowed {
                    handshake,
                    awaiting_confirmation,
                },
                PairingMessage::PakeA { .. },
            ) => {
                let reply = handshake.handle_pake_a(message, now_ms)?;
                pending.deadline_ms = handshake
                    .expires_at_ms()
                    .min(deadline(now_ms, FRAME_PROGRESS_TIMEOUT_MS)?);
                *awaiting_confirmation = true;
                HostEvent::Reply(reply)
            }
            (
                PendingStage::Allowed {
                    handshake,
                    awaiting_confirmation: true,
                },
                PairingMessage::ConfirmA { .. },
            ) => {
                let token_deadline = handshake.expires_at_ms();
                let (session, ready) = handshake.handle_confirm_a(message, now_ms)?;
                pending.deadline_ms =
                    token_deadline.min(deadline(now_ms, FRAME_PROGRESS_TIMEOUT_MS)?);
                pending.stage = PendingStage::Ready(Box::new(session));
                HostEvent::Ready(ready)
            }
            _ => return Err(ProtocolError::PairingState.into()),
        };
        self.pending = Some(pending);
        Ok(event)
    }

    /// Call only when FrameWriter reports Complete for HostEvent::Ready. A
    /// stalled/failed ready write must close_connection instead. No virtual
    /// device may be created merely because this pairing state is Paired.
    pub fn ready_written(&mut self, id: ConnectionId, now_ms: u64) -> Result<(), HostError> {
        self.check_pending(id, now_ms)?;
        let pending = self.pending.take().ok_or(HostError::StaleConnection)?;
        let PendingStage::Ready(session) = pending.stage else {
            self.pending = Some(pending);
            return Err(HostError::InvalidState);
        };
        self.active = Some(Active {
            id,
            session: Some(session),
        });
        Ok(())
    }

    /// The host retains exclusive session ownership. Traffic bytes still need
    /// freshness/path/watchdog/backend validation before any input is allowed.
    pub fn session_mut(&mut self, id: ConnectionId) -> Option<&mut PairedSession> {
        self.active
            .as_mut()
            .filter(|active| active.id == id)
            .and_then(|active| active.session.as_deref_mut())
    }

    /// Transfers traffic ownership to an adapter while retaining the exclusive
    /// active-connection admission slot until close_connection.
    pub fn take_session(&mut self, id: ConnectionId) -> Option<PairedSession> {
        self.active
            .as_mut()
            .filter(|active| active.id == id)?
            .session
            .take()
            .map(|session| *session)
    }

    /// Disconnect, user cancel, permission loss, backgrounding, or listener stop.
    /// Stale callbacks cannot cancel a newer connection. Limits are retained.
    pub fn close_connection(&mut self, id: ConnectionId) -> bool {
        if self
            .pending
            .as_ref()
            .is_some_and(|pending| pending.id == id)
        {
            self.pending = None;
            true
        } else if self.active.as_ref().is_some_and(|active| active.id == id) {
            self.active = None;
            true
        } else {
            false
        }
    }

    /// Run from a timer even with no incoming packets. Returns the socket ID to
    /// close after erasing an expired request/token/pending session.
    pub fn poll_deadline(&mut self, now_ms: u64) -> Result<Option<ConnectionId>, HostError> {
        self.check_clock(now_ms)?;
        if self
            .pending
            .as_ref()
            .is_some_and(|pending| now_ms >= pending.deadline_ms)
        {
            let id = self.pending.take().map(|pending| pending.id);
            Ok(id)
        } else {
            Ok(None)
        }
    }

    fn check_pending(&mut self, id: ConnectionId, now_ms: u64) -> Result<(), HostError> {
        self.check_clock(now_ms)?;
        let pending = self
            .pending
            .as_ref()
            .filter(|pending| pending.id == id)
            .ok_or(HostError::StaleConnection)?;
        if now_ms >= pending.deadline_ms {
            self.pending = None;
            return Err(HostError::DeadlineExpired);
        }
        Ok(())
    }

    fn check_clock(&mut self, now_ms: u64) -> Result<(), HostError> {
        if now_ms < self.last_now_ms {
            self.pending = None;
            self.active = None;
            return Err(HostError::ClockRegression);
        }
        self.last_now_ms = now_ms;
        Ok(())
    }
}

impl std::fmt::Debug for PhonePairingHost {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PhonePairingHost")
            .field("state", &self.state())
            .finish_non_exhaustive()
    }
}

fn deadline(now_ms: u64, timeout_ms: u64) -> Result<u64, HostError> {
    now_ms
        .checked_add(timeout_ms)
        .ok_or(HostError::TimeOverflow)
}
