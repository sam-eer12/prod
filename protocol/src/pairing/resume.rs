//! One bounded, mutually authenticated endpoint/epoch transition.
//! Traffic and input remain isolated while a candidate is pending. The caller
//! neutralizes its backend before starting and rearms only after confirmation.

use super::{PairedSession, Role, random};
use crate::{
    ProtocolError,
    crypto::{SessionSecret, Transport},
    frame::{EpochConfirmPayload, Frame, ResumeChallengePayload, ResumeConfirmPayload},
};
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};
use std::net::SocketAddr;
use subtle::ConstantTimeEq;
use zeroize::Zeroizing;

pub const RESUME_TIMEOUT_MS: u64 = 2_000;
pub const SECRET_LIFETIME_MS: u64 = 30_000;

/// Exact observed candidate endpoints, supplied by the transport on both peers.
/// An endpoint is committed only after both MACs and a new-key neutral ready.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ResumePath {
    pub transport: Transport,
    pub desktop: SocketAddr,
    pub phone: SocketAddr,
}

pub struct SessionLease {
    session: Option<PairedSession>,
    expires_ms: u64,
    reference_ms: u64,
    last_now_ms: u64,
}

impl SessionLease {
    pub fn new(session: PairedSession, now_ms: u64) -> Result<Self, ProtocolError> {
        Ok(Self {
            session: Some(session),
            expires_ms: now_ms
                .checked_add(SECRET_LIFETIME_MS)
                .ok_or(ProtocolError::SessionExpired)?,
            reference_ms: now_ms,
            last_now_ms: now_ms,
        })
    }
    pub const fn expires_ms(&self) -> u64 {
        self.expires_ms
    }
    pub fn check_live(&mut self, now_ms: u64) -> Result<(), ProtocolError> {
        if now_ms < self.last_now_ms {
            self.session = None;
            return Err(ProtocolError::ClockRegression);
        }
        self.last_now_ms = now_ms;
        if now_ms >= self.expires_ms || self.session.is_none() {
            self.session = None;
            return Err(ProtocolError::SessionExpired);
        }
        Ok(())
    }
    pub fn session_mut(&mut self, now_ms: u64) -> Result<&mut PairedSession, ProtocolError> {
        self.check_live(now_ms)?;
        self.session.as_mut().ok_or(ProtocolError::SessionExpired)
    }
    /// Only call after authenticated clock/freshness validation. Sample time,
    /// never packet receipt, anchors expiry. Pings and retries cannot refresh it.
    pub fn fresh_input(&mut self, sample_local_ms: u64, now_ms: u64) -> Result<(), ProtocolError> {
        self.check_live(now_ms)?;
        if sample_local_ms > now_ms {
            return Err(ProtocolError::FutureSampleTime);
        }
        if sample_local_ms < self.reference_ms || now_ms - sample_local_ms >= 250 {
            return Err(ProtocolError::StaleSampleTime);
        }
        self.expires_ms = sample_local_ms
            .checked_add(SECRET_LIFETIME_MS)
            .ok_or(ProtocolError::SessionExpired)?;
        self.reference_ms = sample_local_ms;
        Ok(())
    }
    pub fn close(&mut self) {
        self.session = None;
    }
    pub fn resume(mut self, path: ResumePath, now_ms: u64) -> Result<Resumption, ProtocolError> {
        self.check_live(now_ms)?;
        if path.desktop.port() == 0
            || path.phone.port() == 0
            || path.desktop.ip().is_unspecified()
            || path.phone.ip().is_unspecified()
        {
            return Err(ProtocolError::ResumeState);
        }
        let session = self.session.as_ref().ok_or(ProtocolError::SessionExpired)?;
        let epoch = session
            .epoch()
            .checked_add(1)
            .ok_or(ProtocolError::SequenceExhausted)?;
        let state = match session.role() {
            Role::Desktop => ResumeState::DesktopStart,
            Role::Phone => ResumeState::PhoneChallenge,
        };
        let deadline_ms = self.expires_ms.min(
            now_ms
                .checked_add(RESUME_TIMEOUT_MS)
                .ok_or(ProtocolError::SessionExpired)?,
        );
        Ok(Resumption {
            lease: self,
            path,
            epoch,
            deadline_ms,
            state,
        })
    }
}

enum ResumeState {
    DesktopStart,
    PhoneChallenge,
    DesktopChallenge([u8; 16]),
    PhoneConfirm { a: [u8; 16], b: [u8; 16] },
    DesktopConfirm { a: [u8; 16], b: [u8; 16] },
    DesktopReady(Box<PairedSession>),
    PhoneReady(Box<PairedSession>),
    Complete,
    Failed,
}

/// At most two outgoing frames (phone confirmation and neutral ready).
/// Debug never exposes challenge, transcript, or ciphertext storage.
pub struct ResumeOutput {
    pub frames: Vec<Vec<u8>>,
    pub ready_to_commit: bool,
}
pub struct Resumption {
    lease: SessionLease,
    path: ResumePath,
    epoch: u32,
    deadline_ms: u64,
    state: ResumeState,
}

impl Resumption {
    pub const fn deadline_ms(&self) -> u64 {
        self.deadline_ms
    }
    pub fn begin(&mut self, now_ms: u64) -> Result<Vec<u8>, ProtocolError> {
        self.check_live(now_ms)?;
        if !matches!(self.state, ResumeState::DesktopStart) {
            return Err(ProtocolError::ResumeState);
        }
        let a = random::array()?;
        let transport = self.path.transport;
        let epoch = self.epoch;
        let bytes = self.old()?.seal(
            transport,
            &Frame::ResumeChallenge(ResumeChallengePayload {
                epoch,
                challenge: a,
            }),
        )?;
        self.state = ResumeState::DesktopChallenge(a);
        Ok(bytes)
    }
    pub fn receive(
        &mut self,
        source: SocketAddr,
        bytes: &[u8],
        now_ms: u64,
    ) -> Result<ResumeOutput, ProtocolError> {
        self.check_live(now_ms)?;
        let role = self.old()?.role();
        let expected = if role == Role::Desktop {
            self.path.phone
        } else {
            self.path.desktop
        };
        if source != expected {
            return Err(ProtocolError::ResumeState);
        }
        let result = self.receive_inner(bytes);
        if result.is_err() {
            self.state = ResumeState::Failed;
            self.lease.close();
        }
        result
    }
    fn receive_inner(&mut self, bytes: &[u8]) -> Result<ResumeOutput, ProtocolError> {
        if let ResumeState::DesktopReady(candidate) = &mut self.state {
            let opened = candidate.open(self.path.transport, bytes)?;
            require_ready(&opened.frame, opened.header.seq, self.epoch)?;
            let previous = std::mem::replace(&mut self.state, ResumeState::Complete);
            if let ResumeState::DesktopReady(candidate) = previous {
                self.lease.session = Some(*candidate);
            }
            return Ok(ResumeOutput {
                frames: Vec::new(),
                ready_to_commit: true,
            });
        }
        let transport = self.path.transport;
        let frame = self.old()?.open(transport, bytes)?.frame;
        let previous = std::mem::replace(&mut self.state, ResumeState::Failed);
        let mut frames = Vec::new();
        frames
            .try_reserve_exact(2)
            .map_err(|_| ProtocolError::ResourceExhausted)?;
        match (previous, frame) {
            (ResumeState::PhoneChallenge, Frame::ResumeChallenge(challenge))
                if challenge.epoch == self.epoch =>
            {
                let a = challenge.challenge;
                let b = random::array()?;
                let epoch = self.epoch;
                frames.push(self.old()?.seal(
                    transport,
                    &Frame::ResumeChallenge(ResumeChallengePayload {
                        epoch,
                        challenge: b,
                    }),
                )?);
                self.state = ResumeState::PhoneConfirm { a, b };
            }
            (ResumeState::DesktopChallenge(a), Frame::ResumeChallenge(challenge))
                if challenge.epoch == self.epoch =>
            {
                let b = challenge.challenge;
                let mac = self.proof(Role::Desktop, &a, &b)?;
                let epoch = self.epoch;
                frames.push(self.old()?.seal(
                    transport,
                    &Frame::ResumeConfirm(ResumeConfirmPayload {
                        epoch,
                        challenge_echo: b,
                        mac,
                    }),
                )?);
                self.state = ResumeState::DesktopConfirm { a, b };
            }
            (ResumeState::PhoneConfirm { a, b }, Frame::ResumeConfirm(confirm))
                if confirm.epoch == self.epoch && confirm.challenge_echo == b =>
            {
                if !bool::from(self.proof(Role::Desktop, &a, &b)?.ct_eq(&confirm.mac)) {
                    return Err(ProtocolError::AuthenticationFailed);
                }
                let mac = self.proof(Role::Phone, &a, &b)?;
                let epoch = self.epoch;
                frames.push(self.old()?.seal(
                    transport,
                    &Frame::ResumeConfirm(ResumeConfirmPayload {
                        epoch,
                        challenge_echo: a,
                        mac,
                    }),
                )?);
                let mut candidate = self.candidate(&a, &b)?;
                frames.push(candidate.seal(
                    transport,
                    &Frame::EpochConfirm(EpochConfirmPayload {
                        epoch,
                        baseline_edge_id: 0,
                        flags: EpochConfirmPayload::FLAG_NEUTRAL_BASELINE,
                    }),
                )?);
                self.state = ResumeState::PhoneReady(Box::new(candidate));
            }
            (ResumeState::DesktopConfirm { a, b }, Frame::ResumeConfirm(confirm))
                if confirm.epoch == self.epoch && confirm.challenge_echo == a =>
            {
                if !bool::from(self.proof(Role::Phone, &a, &b)?.ct_eq(&confirm.mac)) {
                    return Err(ProtocolError::AuthenticationFailed);
                }
                self.state = ResumeState::DesktopReady(Box::new(self.candidate(&a, &b)?));
            }
            _ => return Err(ProtocolError::ResumeState),
        }
        Ok(ResumeOutput {
            frames,
            ready_to_commit: false,
        })
    }
    /// Phone transport acknowledges all queued confirmation/ready bytes written.
    pub fn ready_written(&mut self, now_ms: u64) -> Result<(), ProtocolError> {
        self.check_live(now_ms)?;
        let old = std::mem::replace(&mut self.state, ResumeState::Failed);
        if let ResumeState::PhoneReady(candidate) = old {
            self.lease.session = Some(*candidate);
            self.state = ResumeState::Complete;
            Ok(())
        } else {
            self.lease.close();
            Err(ProtocolError::ResumeState)
        }
    }
    /// Commit exposes the new endpoint and epoch together. Expiry remains the
    /// original input-anchored deadline; a neutral frame does not refresh it.
    pub fn finish(mut self, now_ms: u64) -> Result<(SessionLease, ResumePath), ProtocolError> {
        self.check_live(now_ms)?;
        if !matches!(self.state, ResumeState::Complete) {
            return Err(ProtocolError::ResumeState);
        }
        Ok((self.lease, self.path))
    }
    pub fn check_live(&mut self, now_ms: u64) -> Result<(), ProtocolError> {
        let result = self.lease.check_live(now_ms);
        if result.is_err() || now_ms >= self.deadline_ms {
            self.lease.close();
            self.state = ResumeState::Failed;
            return result.and(Err(ProtocolError::SessionExpired));
        }
        Ok(())
    }
    fn old(&mut self) -> Result<&mut PairedSession, ProtocolError> {
        self.lease
            .session
            .as_mut()
            .ok_or(ProtocolError::SessionExpired)
    }
    fn context(&self, a: &[u8; 16], b: &[u8; 16]) -> Result<Vec<u8>, ProtocolError> {
        let old = self
            .lease
            .session
            .as_ref()
            .ok_or(ProtocolError::SessionExpired)?;
        let mut context = Vec::new();
        context
            .try_reserve_exact(160)
            .map_err(|_| ProtocolError::ResourceExhausted)?;
        context.extend_from_slice(b"padlink/v1/resume-transcript");
        context.extend_from_slice(old.session_id().as_bytes());
        context.extend_from_slice(&old.epoch().to_le_bytes());
        context.extend_from_slice(&self.epoch.to_le_bytes());
        context.push(self.path.transport as u8);
        for endpoint in [self.path.desktop, self.path.phone] {
            match endpoint {
                SocketAddr::V4(addr) => {
                    context.push(4);
                    context.extend_from_slice(&addr.ip().octets());
                    context.extend_from_slice(&addr.port().to_le_bytes());
                }
                SocketAddr::V6(addr) => {
                    context.push(6);
                    context.extend_from_slice(&addr.ip().octets());
                    context.extend_from_slice(&addr.port().to_le_bytes());
                    // Scope/flow IDs are local routing metadata, not shared
                    // endpoint identity; peer interface indices may differ.
                }
            }
        }
        context.extend_from_slice(a);
        context.extend_from_slice(b);
        Ok(context)
    }
    fn proof(&self, role: Role, a: &[u8; 16], b: &[u8; 16]) -> Result<[u8; 32], ProtocolError> {
        let old = self
            .lease
            .session
            .as_ref()
            .ok_or(ProtocolError::SessionExpired)?;
        let mut key = Zeroizing::new([0; 32]);
        Hkdf::<Sha256>::new(Some(old.session_id().as_bytes()), old.root.expose())
            .expand(b"padlink/v1/resume-mac", key.as_mut())
            .map_err(|_| ProtocolError::ResumeState)?;
        let mut mac =
            Hmac::<Sha256>::new_from_slice(key.as_ref()).map_err(|_| ProtocolError::ResumeState)?;
        mac.update(&[if role == Role::Desktop { 1 } else { 2 }]);
        mac.update(&self.context(a, b)?);
        Ok(mac.finalize().into_bytes().into())
    }
    fn candidate(&self, a: &[u8; 16], b: &[u8; 16]) -> Result<PairedSession, ProtocolError> {
        let old = self
            .lease
            .session
            .as_ref()
            .ok_or(ProtocolError::SessionExpired)?;
        let salt = Sha256::digest(self.context(a, b)?);
        let mut root = Zeroizing::new([0; 32]);
        Hkdf::<Sha256>::new(Some(&salt), old.root.expose())
            .expand(b"padlink/v1/resume-root", root.as_mut())
            .map_err(|_| ProtocolError::ResumeState)?;
        PairedSession::new_epoch(
            SessionSecret::from_bytes(*root),
            old.session_id(),
            old.role(),
            self.epoch,
        )
    }
}

fn require_ready(frame: &Frame, seq: u64, epoch: u32) -> Result<(), ProtocolError> {
    if matches!(frame, Frame::EpochConfirm(value) if value.epoch == epoch && value.baseline_edge_id == 0 && value.flags == EpochConfirmPayload::FLAG_NEUTRAL_BASELINE)
        && seq == 0
    {
        Ok(())
    } else {
        Err(ProtocolError::ResumeState)
    }
}
impl std::fmt::Debug for SessionLease {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("SessionLease([redacted])")
    }
}
impl std::fmt::Debug for Resumption {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Resumption([redacted])")
    }
}
impl std::fmt::Debug for ResumeOutput {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("ResumeOutput([redacted])")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto::SessionId;
    fn pair() -> (Resumption, Resumption) {
        let path = ResumePath {
            transport: Transport::Tcp,
            desktop: "127.0.0.1:1000".parse().unwrap(),
            phone: "127.0.0.1:1001".parse().unwrap(),
        };
        let session = |role| {
            PairedSession::new(
                SessionSecret::from_bytes([7; 32]),
                SessionId::from_bytes([8; 16]),
                role,
            )
            .unwrap()
        };
        (
            SessionLease::new(session(Role::Desktop), 0)
                .unwrap()
                .resume(path, 0)
                .unwrap(),
            SessionLease::new(session(Role::Phone), 0)
                .unwrap()
                .resume(path, 0)
                .unwrap(),
        )
    }
    #[test]
    fn valid_aead_with_bad_or_reflected_confirmation_mac_fails_closed() {
        for reflected in [false, true] {
            let (mut desktop, mut phone) = pair();
            let a = desktop.begin(0).unwrap();
            let b = phone
                .receive(phone.path.desktop, &a, 1)
                .unwrap()
                .frames
                .remove(0);
            let _ca = desktop.receive(desktop.path.phone, &b, 2).unwrap();
            let ResumeState::PhoneConfirm { a, b } = phone.state else {
                panic!("state")
            };
            let mac = if reflected {
                phone.proof(Role::Phone, &a, &b).unwrap()
            } else {
                [0; 32]
            };
            let frame = Frame::ResumeConfirm(ResumeConfirmPayload {
                epoch: phone.epoch,
                challenge_echo: b,
                mac,
            });
            let forged = desktop.old().unwrap().seal(Transport::Tcp, &frame).unwrap();
            assert!(phone.receive(phone.path.desktop, &forged, 3).is_err());
            assert!(phone.old().is_err());
            assert!(phone.finish(4).is_err());
        }
    }
    #[test]
    fn unwritten_ready_cannot_commit_and_timeout_erases_candidate() {
        let (mut desktop, mut phone) = pair();
        let a = desktop.begin(0).unwrap();
        let b = phone
            .receive(phone.path.desktop, &a, 1)
            .unwrap()
            .frames
            .remove(0);
        let ca = desktop
            .receive(desktop.path.phone, &b, 2)
            .unwrap()
            .frames
            .remove(0);
        phone.receive(phone.path.desktop, &ca, 3).unwrap();
        assert!(matches!(phone.state, ResumeState::PhoneReady(_)));
        assert!(phone.check_live(RESUME_TIMEOUT_MS).is_err());
        assert!(matches!(phone.state, ResumeState::Failed));
        assert!(phone.ready_written(RESUME_TIMEOUT_MS).is_err());
        assert!(phone.finish(RESUME_TIMEOUT_MS).is_err());
    }
    #[test]
    fn ipv6_scope_indices_are_local_but_address_and_port_are_bound() {
        let (mut desktop, mut phone) = pair();
        desktop.path.desktop = "[fe80::1%3]:1000".parse().unwrap();
        desktop.path.phone = "[fe80::2%3]:1001".parse().unwrap();
        phone.path.desktop = "[fe80::1%21]:1000".parse().unwrap();
        phone.path.phone = "[fe80::2%21]:1001".parse().unwrap();
        let a = [1; 16];
        let b = [2; 16];
        assert_eq!(
            desktop.proof(Role::Desktop, &a, &b).unwrap(),
            phone.proof(Role::Desktop, &a, &b).unwrap()
        );
        phone.path.phone.set_port(2000);
        assert_ne!(
            desktop.proof(Role::Desktop, &a, &b).unwrap(),
            phone.proof(Role::Desktop, &a, &b).unwrap()
        );
    }
}
