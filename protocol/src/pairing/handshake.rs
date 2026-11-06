//! Single-request pairing state machines. All clocks are local monotonic ms.
//! A transport must bound reads, retain attempt accounting across retries,
//! cancel abandoned requests, enforce request rate limits, and drive expiry.

use pakery_spake2::Spake2Output;

use super::pake::{self, Context, DesktopPake};
use super::random;
use super::session::{PairedSession, Role};
use super::wire::{PairingAccept, PairingMessage, PairingRequest};
use super::{PAKE_POINT_LEN, PAKE_SUITE};
use crate::code::{PAIRING_TOKEN_TTL_MS, PairingToken};
use crate::crypto::SessionId;
use crate::{PROTOCOL_VERSION, ProtocolError};

enum DesktopState {
    WaitingAccept,
    ReadyForCode,
    WaitingPakeB {
        pake: Box<DesktopPake>,
        point: [u8; PAKE_POINT_LEN],
    },
    WaitingReady(Box<PairedSession>),
    Complete,
    Aborted,
}

/// Desktop initiator. No session can be extracted until the phone's key
/// confirmation and encrypted neutral-ready frame both authenticate.
pub struct DesktopHandshake {
    request: PairingRequest,
    context: Option<Context>,
    deadline_ms: Option<u64>,
    state: DesktopState,
}

impl DesktopHandshake {
    pub fn new(desktop_label: &str) -> Result<Self, ProtocolError> {
        super::wire::validate_label(desktop_label)?;
        let request = PairingRequest {
            version: PROTOCOL_VERSION,
            suite: PAKE_SUITE,
            request_id: random::array()?,
            desktop_nonce: random::array()?,
            desktop_label: desktop_label.to_owned(),
        };
        request.validate()?;
        Ok(Self {
            request,
            context: None,
            deadline_ms: None,
            state: DesktopState::WaitingAccept,
        })
    }

    pub fn request(&self) -> PairingMessage {
        PairingMessage::Request(self.request.clone())
    }
    pub const fn deadline_ms(&self) -> Option<u64> {
        self.deadline_ms
    }

    pub fn accept(&mut self, message: &PairingMessage, now_ms: u64) -> Result<(), ProtocolError> {
        self.check_message(message)?;
        if !matches!(self.state, DesktopState::WaitingAccept) {
            return Err(ProtocolError::PairingState);
        }
        let PairingMessage::Accept(accept) = message else {
            return Err(ProtocolError::PairingState);
        };
        super::wire::validate_selection(accept.version, accept.suite)?;
        self.deadline_ms = Some(
            now_ms
                .checked_add(PAIRING_TOKEN_TTL_MS)
                .ok_or(ProtocolError::PairingState)?,
        );
        self.context = Some(Context {
            request: self.request.clone(),
            accept: accept.clone(),
        });
        self.state = DesktopState::ReadyForCode;
        Ok(())
    }

    /// Starts a fresh ephemeral attempt. A failed exchange never reuses its
    /// scalar or confirmation state. The phone owns the shared attempt budget.
    pub fn start_attempt(
        &mut self,
        code: &str,
        now_ms: u64,
    ) -> Result<PairingMessage, ProtocolError> {
        self.check_deadline(now_ms)?;
        if !matches!(self.state, DesktopState::ReadyForCode) {
            return Err(ProtocolError::PairingState);
        }
        let context = self.context.as_ref().ok_or(ProtocolError::PairingState)?;
        let (point, pake) = context.start_desktop(code)?;
        self.state = DesktopState::WaitingPakeB {
            pake: Box::new(pake),
            point,
        };
        Ok(PairingMessage::PakeA {
            request_id: self.request.request_id,
            point,
        })
    }

    pub fn handle_pake_b(
        &mut self,
        message: &PairingMessage,
        now_ms: u64,
    ) -> Result<PairingMessage, ProtocolError> {
        self.check_deadline(now_ms)?;
        self.check_message(message)?;
        let PairingMessage::PakeB {
            point: pb,
            confirmation: cb,
            ..
        } = message
        else {
            return Err(ProtocolError::PairingState);
        };
        let previous = std::mem::replace(&mut self.state, DesktopState::Aborted);
        let DesktopState::WaitingPakeB {
            pake: state,
            point: pa,
        } = previous
        else {
            return Err(ProtocolError::PairingState);
        };
        // On any failed PAKE, the consumed state is dropped. A manual retry is
        // possible within this request's deadline and phone's attempt budget.
        self.state = DesktopState::ReadyForCode;
        pake::validate_point(pb)?;
        let output = state.finish(pb).map_err(|_| ProtocolError::PakeFailed)?;
        output
            .verify_peer_confirmation(cb)
            .map_err(|_| ProtocolError::PakeFailed)?;
        let ca = pake::confirmation(&output)?;
        let context = self.context.as_ref().ok_or(ProtocolError::PairingState)?;
        let root = pake::session_root(&output, &context.transcript_salt(&pa, pb))?;
        let session = PairedSession::new(root, context.accept.session_id, Role::Desktop)?;
        self.state = DesktopState::WaitingReady(Box::new(session));
        Ok(PairingMessage::ConfirmA {
            request_id: self.request.request_id,
            confirmation: ca,
        })
    }

    pub fn finish(&mut self, ready: &[u8], now_ms: u64) -> Result<PairedSession, ProtocolError> {
        self.check_deadline(now_ms)?;
        let previous = std::mem::replace(&mut self.state, DesktopState::Aborted);
        let DesktopState::WaitingReady(mut session) = previous else {
            return Err(ProtocolError::PairingState);
        };
        session.verify_ready(ready)?;
        self.state = DesktopState::Complete;
        Ok(*session)
    }

    /// Discards a pending exchange after a bounded transport timeout. This
    /// does not issue a new request, reset the deadline, or replenish attempts.
    pub fn retry(&mut self, now_ms: u64) -> Result<(), ProtocolError> {
        self.check_deadline(now_ms)?;
        if !matches!(
            self.state,
            DesktopState::ReadyForCode
                | DesktopState::WaitingPakeB { .. }
                | DesktopState::WaitingReady(_)
        ) {
            return Err(ProtocolError::PairingState);
        }
        self.state = DesktopState::ReadyForCode;
        Ok(())
    }

    pub fn cancel(&mut self) {
        self.state = DesktopState::Aborted;
        self.context = None;
    }

    fn check_deadline(&mut self, now_ms: u64) -> Result<(), ProtocolError> {
        if self.deadline_ms.is_some_and(|deadline| now_ms >= deadline) {
            self.cancel();
            return Err(ProtocolError::PairingTokenExpired);
        }
        Ok(())
    }

    fn check_message(&mut self, message: &PairingMessage) -> Result<(), ProtocolError> {
        if message.request_id() != &self.request.request_id {
            self.cancel();
            return Err(ProtocolError::PairingRequestMismatch);
        }
        if let PairingMessage::Abort { reason, .. } = message {
            let reason = *reason;
            self.cancel();
            return Err(ProtocolError::PairingAborted { reason });
        }
        Ok(())
    }
}

enum PhoneState {
    WaitingPakeA,
    WaitingConfirm {
        output: Spake2Output,
        salt: [u8; 32],
    },
    Complete,
    Aborted,
}

/// One request explicitly allowed by the phone user. Reopening a TCP socket
/// must not create a replacement instance or token without fresh consent.
pub struct PhoneHandshake {
    context: Context,
    token: PairingToken,
    state: PhoneState,
}

impl PhoneHandshake {
    /// The only token-issuance step: call after the phone's real Allow action.
    /// Parsing, discovery, and receipt of a Request never invoke this step.
    pub fn consent(request: &PairingRequest, now_ms: u64) -> Result<Self, ProtocolError> {
        request.validate()?;
        let accept = PairingAccept {
            version: PROTOCOL_VERSION,
            suite: PAKE_SUITE,
            request_id: request.request_id,
            phone_nonce: random::array()?,
            session_id: SessionId::generate()?,
        };
        let token = PairingToken::issue(now_ms)?;
        Ok(Self {
            context: Context {
                request: request.clone(),
                accept,
            },
            token,
            state: PhoneState::WaitingPakeA,
        })
    }

    pub fn accept(&self) -> PairingMessage {
        PairingMessage::Accept(self.context.accept.clone())
    }
    pub fn expires_at_ms(&self) -> u64 {
        self.token.expires_at_ms()
    }
    pub fn attempts_remaining(&self) -> u8 {
        self.token.attempts_remaining()
    }

    /// UI-only token access. Expired codes are erased before returning.
    pub fn display_code(&mut self, now_ms: u64) -> Result<&str, ProtocolError> {
        self.check_live(now_ms)?;
        self.token
            .display_code()
            .ok_or(ProtocolError::PairingTokenLocked)
    }

    pub fn handle_pake_a(
        &mut self,
        message: &PairingMessage,
        now_ms: u64,
    ) -> Result<PairingMessage, ProtocolError> {
        self.check_live(now_ms)?;
        self.check_message(message)?;
        let PairingMessage::PakeA { point: pa, .. } = message else {
            return Err(ProtocolError::PairingState);
        };
        if !matches!(
            self.state,
            PhoneState::WaitingPakeA | PhoneState::WaitingConfirm { .. }
        ) {
            return Err(ProtocolError::PairingState);
        }
        pake::validate_point(pa)?;
        // A new valid PakeA abandons the preceding reserved attempt. It never
        // replenishes the budget or moves the consent deadline.
        if matches!(self.state, PhoneState::WaitingConfirm { .. }) {
            self.fail_attempt();
        }
        self.token.begin_attempt(now_ms)?;
        let response = self.context.respond_phone(
            self.token
                .display_code()
                .ok_or(ProtocolError::PairingTokenLocked)?,
            pa,
        );
        let (pb, output) = match response {
            Ok(response) => response,
            Err(error) => {
                self.fail_attempt();
                return Err(error);
            }
        };
        let cb = pake::confirmation(&output)?;
        let salt = self.context.transcript_salt(pa, &pb);
        self.state = PhoneState::WaitingConfirm { output, salt };
        Ok(PairingMessage::PakeB {
            request_id: self.context.request.request_id,
            point: pb,
            confirmation: cb,
        })
    }

    /// Releases the phone session and seals the ready frame only after cA has
    /// authenticated. No failed/expired exchange can yield traffic keys.
    pub fn handle_confirm_a(
        &mut self,
        message: &PairingMessage,
        now_ms: u64,
    ) -> Result<(PairedSession, Vec<u8>), ProtocolError> {
        self.check_live(now_ms)?;
        self.check_message(message)?;
        let PairingMessage::ConfirmA {
            confirmation: ca, ..
        } = message
        else {
            return Err(ProtocolError::PairingState);
        };
        let previous = std::mem::replace(&mut self.state, PhoneState::WaitingPakeA);
        let PhoneState::WaitingConfirm { output, salt } = previous else {
            return Err(ProtocolError::PairingState);
        };
        if output.verify_peer_confirmation(ca).is_err() {
            self.fail_attempt();
            return Err(ProtocolError::PakeFailed);
        }
        let result = (|| {
            let root = pake::session_root(&output, &salt)?;
            let mut session =
                PairedSession::new(root, self.context.accept.session_id, Role::Phone)?;
            let ready = session.ready()?;
            Ok((session, ready))
        })();
        self.token.invalidate();
        self.state = if result.is_ok() {
            PhoneState::Complete
        } else {
            PhoneState::Aborted
        };
        result
    }

    /// Marks an unfinished reserved attempt failed (e.g. transport timeout).
    pub fn fail_attempt(&mut self) {
        self.token.fail_attempt();
        self.state = if self.token.display_code().is_some() {
            PhoneState::WaitingPakeA
        } else {
            PhoneState::Aborted
        };
    }

    pub fn cancel(&mut self) {
        self.token.invalidate();
        self.state = PhoneState::Aborted;
    }

    /// Transport timers must call this even when no more messages arrive.
    pub fn check_live(&mut self, now_ms: u64) -> Result<(), ProtocolError> {
        if self.token.display_code().is_none() {
            return Err(ProtocolError::PairingTokenLocked);
        }
        if now_ms >= self.token.expires_at_ms() {
            self.cancel();
            return Err(ProtocolError::PairingTokenExpired);
        }
        Ok(())
    }

    fn check_message(&mut self, message: &PairingMessage) -> Result<(), ProtocolError> {
        if message.request_id() != &self.context.request.request_id {
            self.cancel();
            return Err(ProtocolError::PairingRequestMismatch);
        }
        if let PairingMessage::Abort { reason, .. } = message {
            let reason = *reason;
            self.cancel();
            return Err(ProtocolError::PairingAborted { reason });
        }
        Ok(())
    }
}

impl std::fmt::Debug for DesktopHandshake {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("DesktopHandshake([redacted])")
    }
}
impl std::fmt::Debug for PhoneHandshake {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PhoneHandshake")
            .field("attempts_remaining", &self.attempts_remaining())
            .finish_non_exhaustive()
    }
}
