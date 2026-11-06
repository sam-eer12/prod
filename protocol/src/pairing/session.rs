//! Session traffic ownership after pairing. No controller, sockets, path
//! migration, or watchdog driver is attached by this type.

use crate::ProtocolError;
use crate::crypto::{
    Direction, KeyDomain, OpenedFrame, ReplayWindow, SessionId, SessionSecret, TrafficKey,
    Transport,
};
use crate::frame::{EpochConfirmPayload, Frame};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    Desktop,
    Phone,
}

/// Mutually confirmed pairing traffic. The root and all four directional keys
/// remain in memory only and erase their owned secret storage on drop.
/// Obtaining this object is not authorization to inject real controller input.
pub struct PairedSession {
    session_id: SessionId,
    role: Role,
    pub(crate) root: SessionSecret,
    epoch: u32,
    send_udp: TrafficKey,
    receive_udp: TrafficKey,
    send_tcp: TrafficKey,
    receive_tcp: TrafficKey,
    replay_udp: ReplayWindow,
    replay_tcp: ReplayWindow,
}

impl PairedSession {
    pub(crate) fn new(
        root: SessionSecret,
        session_id: SessionId,
        role: Role,
    ) -> Result<Self, ProtocolError> {
        Self::new_epoch(root, session_id, role, 1)
    }

    pub(crate) fn new_epoch(
        root: SessionSecret,
        session_id: SessionId,
        role: Role,
        epoch: u32,
    ) -> Result<Self, ProtocolError> {
        let send = match role {
            Role::Desktop => Direction::DesktopToPhone,
            Role::Phone => Direction::PhoneToDesktop,
        };
        let receive = send.opposite();
        let derive = |direction, transport| {
            TrafficKey::derive(
                &root,
                session_id,
                KeyDomain::new(direction, transport, epoch),
            )
        };
        let send_udp = derive(send, Transport::Udp)?;
        let receive_udp = derive(receive, Transport::Udp)?;
        let send_tcp = derive(send, Transport::Tcp)?;
        let receive_tcp = derive(receive, Transport::Tcp)?;
        Ok(Self {
            session_id,
            role,
            root,
            epoch,
            send_udp,
            receive_udp,
            send_tcp,
            receive_tcp,
            replay_udp: ReplayWindow::new(),
            replay_tcp: ReplayWindow::new(),
        })
    }

    pub const fn session_id(&self) -> SessionId {
        self.session_id
    }
    pub const fn role(&self) -> Role {
        self.role
    }

    pub const fn epoch(&self) -> u32 {
        self.epoch
    }

    /// UDP returns an envelope; TCP returns a complete length-prefixed frame.
    pub fn seal(&mut self, transport: Transport, frame: &Frame) -> Result<Vec<u8>, ProtocolError> {
        match transport {
            Transport::Udp => self.send_udp.seal_frame(frame),
            Transport::Tcp => self.send_tcp.seal_tcp_frame(frame),
        }
    }

    pub fn open(
        &mut self,
        transport: Transport,
        bytes: &[u8],
    ) -> Result<OpenedFrame, ProtocolError> {
        match transport {
            Transport::Udp => self.receive_udp.open_frame(bytes, &mut self.replay_udp),
            Transport::Tcp => self.receive_tcp.open_tcp_frame(bytes, &mut self.replay_tcp),
        }
    }

    pub(crate) fn ready(&mut self) -> Result<Vec<u8>, ProtocolError> {
        if self.role != Role::Phone || self.send_tcp.next_sequence() != 0 {
            return Err(ProtocolError::PairingState);
        }
        self.seal(
            Transport::Tcp,
            &Frame::EpochConfirm(EpochConfirmPayload {
                epoch: 1,
                baseline_edge_id: 0,
                flags: EpochConfirmPayload::FLAG_NEUTRAL_BASELINE,
            }),
        )
    }

    pub(crate) fn verify_ready(&mut self, bytes: &[u8]) -> Result<(), ProtocolError> {
        if self.role != Role::Desktop {
            return Err(ProtocolError::PairingState);
        }
        let opened = self.open(Transport::Tcp, bytes)?;
        if opened.header.seq != 0 {
            return Err(ProtocolError::PairingState);
        }
        match opened.frame {
            Frame::EpochConfirm(epoch)
                if epoch.epoch == 1
                    && epoch.baseline_edge_id == 0
                    && epoch.flags == EpochConfirmPayload::FLAG_NEUTRAL_BASELINE =>
            {
                Ok(())
            }
            _ => Err(ProtocolError::PairingState),
        }
    }
}

impl std::fmt::Debug for PairedSession {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PairedSession")
            .field("role", &self.role)
            .finish_non_exhaustive()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session(role: Role) -> PairedSession {
        PairedSession::new(
            SessionSecret::from_bytes([0x31; 32]),
            SessionId::from_bytes([0x42; 16]),
            role,
        )
        .unwrap()
    }

    #[test]
    fn authenticated_ready_requires_exact_type_epoch_flag_and_sequence() {
        for (epoch, flags) in [(2, 1), (1, 0)] {
            let mut phone = session(Role::Phone);
            let mut desktop = session(Role::Desktop);
            let packet = phone
                .seal(
                    Transport::Tcp,
                    &Frame::EpochConfirm(EpochConfirmPayload {
                        epoch,
                        baseline_edge_id: 0,
                        flags,
                    }),
                )
                .unwrap();
            assert_eq!(
                desktop.verify_ready(&packet),
                Err(ProtocolError::PairingState)
            );
        }
        let mut phone = session(Role::Phone);
        let mut desktop = session(Role::Desktop);
        let packet = phone
            .seal(
                Transport::Tcp,
                &Frame::Ack(crate::frame::AckPayload::default()),
            )
            .unwrap();
        assert_eq!(
            desktop.verify_ready(&packet),
            Err(ProtocolError::PairingState)
        );
        let packet = phone
            .seal(
                Transport::Tcp,
                &Frame::EpochConfirm(EpochConfirmPayload {
                    epoch: 1,
                    baseline_edge_id: 0,
                    flags: 1,
                }),
            )
            .unwrap();
        assert_eq!(
            desktop.verify_ready(&packet),
            Err(ProtocolError::PairingState)
        );
    }

    #[test]
    fn ready_is_sealed_once_and_only_by_phone() {
        let mut phone = session(Role::Phone);
        assert!(phone.ready().is_ok());
        assert_eq!(phone.ready(), Err(ProtocolError::PairingState));
        let mut desktop = session(Role::Desktop);
        assert_eq!(desktop.ready(), Err(ProtocolError::PairingState));
    }
}
