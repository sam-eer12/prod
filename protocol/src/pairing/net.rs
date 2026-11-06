//! Bounded foreground pairing adapters. The phone owns one listener/channel;
//! desktop construction has a three-second connect bound, then IO is polled.
//! These adapters never mount a gamepad or inject controller input.
use super::{
    DesktopHandshake, PairingMessage,
    host::{ConnectionId, HostError, HostEvent, HostState, PhonePairingHost},
    resume::SessionLease,
    transport::{FrameMode, FrameReader, FrameWriter, ReadStatus, TransportError, WriteStatus},
};
use crate::{
    ProtocolError,
    crypto::Transport,
    frame::{Frame, PongPayload},
};
use std::{
    net::{Shutdown, SocketAddr, TcpListener, TcpStream},
    time::Duration,
};

#[derive(Debug)]
pub enum NetworkError {
    Io(std::io::ErrorKind),
    Protocol(ProtocolError),
    Host(HostError),
    Framing(TransportError),
    State,
}
impl std::fmt::Display for NetworkError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(kind) => write!(f, "network IO failed ({kind:?})"),
            Self::Protocol(e) => e.fmt(f),
            Self::Host(e) => e.fmt(f),
            Self::Framing(e) => e.fmt(f),
            Self::State => f.write_str("invalid pairing channel state"),
        }
    }
}
impl std::error::Error for NetworkError {}
impl From<ProtocolError> for NetworkError {
    fn from(e: ProtocolError) -> Self {
        Self::Protocol(e)
    }
}
impl From<HostError> for NetworkError {
    fn from(e: HostError) -> Self {
        Self::Host(e)
    }
}
impl From<TransportError> for NetworkError {
    fn from(e: TransportError) -> Self {
        Self::Framing(e)
    }
}
impl From<std::io::Error> for NetworkError {
    fn from(e: std::io::Error) -> Self {
        Self::Io(e.kind())
    }
}

pub enum PhoneEvent {
    Pending,
    Consent {
        id: u64,
        label: String,
        address: SocketAddr,
    },
    Paired {
        id: u64,
    },
    Closed {
        id: u64,
    },
    Frame(Frame),
}
enum AfterWrite {
    Handshake,
    Ready,
    Data,
    Close,
}
struct PhoneChannel {
    id: ConnectionId,
    socket: TcpStream,
    reader: FrameReader,
    writer: FrameWriter,
    after_write: AfterWrite,
    lease: Option<SessionLease>,
}
pub struct PhonePairingServer {
    host: PhonePairingHost,
    listener: Option<TcpListener>,
    channel: Option<PhoneChannel>,
}
impl PhonePairingServer {
    pub const fn new(now_ms: u64) -> Self {
        Self {
            host: PhonePairingHost::new(now_ms),
            listener: None,
            channel: None,
        }
    }
    pub fn start(&mut self, address: SocketAddr) -> Result<SocketAddr, NetworkError> {
        if self.listener.is_some() {
            return Err(NetworkError::State);
        }
        let listener = match TcpListener::bind(address) {
            Err(error) if error.kind() == std::io::ErrorKind::AddrInUse => {
                let mut fallback = address;
                fallback.set_port(0);
                TcpListener::bind(fallback)?
            }
            result => result?,
        };
        listener.set_nonblocking(true)?;
        let bound = listener.local_addr()?;
        self.listener = Some(listener);
        Ok(bound)
    }
    pub fn stop(&mut self) {
        self.listener = None;
        if let Some(channel) = self.channel.take() {
            self.host.close_connection(channel.id);
            let _ = channel.socket.shutdown(Shutdown::Both);
        }
    }
    pub fn state(&self) -> HostState {
        self.host.state()
    }
    pub fn deadline_ms(&self) -> Option<u64> {
        self.host.deadline_ms()
    }
    pub fn code(&mut self, id: u64, now_ms: u64) -> Result<&str, NetworkError> {
        let current = self.id(id)?;
        Ok(self.host.display_code(current, now_ms)?)
    }
    fn id(&self, id: u64) -> Result<ConnectionId, NetworkError> {
        self.channel
            .as_ref()
            .filter(|channel| channel.id.value() == id)
            .map(|channel| channel.id)
            .ok_or(NetworkError::State)
    }
    pub fn allow(&mut self, id: u64, now_ms: u64) -> Result<(), NetworkError> {
        let current = self.id(id)?;
        if !self
            .channel
            .as_ref()
            .is_some_and(|channel| channel.reader.is_idle() && !channel.writer.is_pending())
        {
            return Err(NetworkError::State);
        }
        let message = self.host.allow(current, now_ms)?;
        let deadline = self.host.deadline_ms().ok_or(NetworkError::State)?;
        let channel = self.channel.as_mut().ok_or(NetworkError::State)?;
        channel.reader = FrameReader::new(FrameMode::Handshake, now_ms, deadline)?;
        channel
            .writer
            .queue(FrameMode::Handshake, &message.encode()?, now_ms, deadline)?;
        channel.after_write = AfterWrite::Handshake;
        Ok(())
    }
    pub fn deny(&mut self, id: u64, now_ms: u64) -> Result<(), NetworkError> {
        let current = self.id(id)?;
        let abort = self.host.deny(current, now_ms)?;
        let channel = self.channel.as_mut().ok_or(NetworkError::State)?;
        channel.writer.queue(
            FrameMode::Handshake,
            &abort.encode()?,
            now_ms,
            now_ms.saturating_add(3000),
        )?;
        channel.after_write = AfterWrite::Close;
        Ok(())
    }
    pub fn disconnect(&mut self, id: u64) -> Result<(), NetworkError> {
        let current = self.id(id)?;
        self.host.close_connection(current);
        if let Some(channel) = self.channel.take() {
            let _ = channel.socket.shutdown(Shutdown::Both);
        }
        Ok(())
    }
    /// Move the live, memory-only lease to a transport owner. The old socket
    /// and listener close; admission history remains on this phone server.
    /// A new endpoint must pass Resumption before ordinary traffic resumes.
    pub fn detach_session(&mut self, id: u64, now_ms: u64) -> Result<SessionLease, NetworkError> {
        self.id(id)?;
        let channel = self.channel.as_mut().ok_or(NetworkError::State)?;
        if channel.writer.is_pending() {
            return Err(NetworkError::State);
        }
        channel
            .lease
            .as_mut()
            .ok_or(NetworkError::State)?
            .check_live(now_ms)?;
        let lease = channel.lease.take().ok_or(NetworkError::State)?;
        self.stop();
        Ok(lease)
    }
    pub fn poll(&mut self, now_ms: u64) -> Result<PhoneEvent, NetworkError> {
        let result = self.poll_inner(now_ms);
        if result.is_err() {
            self.stop();
        }
        result
    }
    fn poll_inner(&mut self, now_ms: u64) -> Result<PhoneEvent, NetworkError> {
        if let Some(id) = self.host.poll_deadline(now_ms)? {
            if let Some(channel) = self.channel.take() {
                let _ = channel.socket.shutdown(Shutdown::Both);
            }
            return Ok(PhoneEvent::Closed { id: id.value() });
        }
        // Reject at most one accepted socket per turn and still service the
        // current channel; connection floods cannot starve its deadline/IO.
        if let Some(listener) = &self.listener {
            match listener.accept() {
                Ok((socket, source)) => match self.host.begin_connection(source.ip(), now_ms) {
                    Ok(id) => {
                        if let Err(e) = configure(&socket) {
                            self.host.close_connection(id);
                            return Err(e);
                        }
                        self.channel = Some(PhoneChannel {
                            id,
                            socket,
                            reader: FrameReader::new(
                                FrameMode::Handshake,
                                now_ms,
                                self.host.deadline_ms().ok_or(NetworkError::State)?,
                            )?,
                            writer: FrameWriter::new(now_ms),
                            after_write: AfterWrite::Handshake,
                            lease: None,
                        });
                    }
                    Err(HostError::Busy | HostError::RateLimited { .. }) => drop(socket),
                    Err(e) => return Err(e.into()),
                },
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
                Err(e) => return Err(e.into()),
            }
        }
        let Some(mut channel) = self.channel.take() else {
            return Ok(PhoneEvent::Pending);
        };
        let result = self.service(&mut channel, now_ms);
        match result {
            Ok(PhoneEvent::Closed { id }) => {
                self.host.close_connection(channel.id);
                let _ = channel.socket.shutdown(Shutdown::Both);
                Ok(PhoneEvent::Closed { id })
            }
            Ok(event) => {
                self.channel = Some(channel);
                Ok(event)
            }
            Err(_error) => {
                self.host.close_connection(channel.id);
                let _ = channel.socket.shutdown(Shutdown::Both);
                Ok(PhoneEvent::Closed {
                    id: channel.id.value(),
                })
            }
        }
    }
    fn service(
        &mut self,
        channel: &mut PhoneChannel,
        now_ms: u64,
    ) -> Result<PhoneEvent, NetworkError> {
        if let Some(lease) = &mut channel.lease {
            lease.check_live(now_ms)?;
        }
        if channel.writer.is_pending() {
            if channel.writer.poll_write(&mut channel.socket, now_ms)? == WriteStatus::Pending {
                return Ok(PhoneEvent::Pending);
            }
            match channel.after_write {
                AfterWrite::Close => {
                    return Ok(PhoneEvent::Closed {
                        id: channel.id.value(),
                    });
                }
                AfterWrite::Ready => {
                    self.host.ready_written(channel.id, now_ms)?;
                    let session = self
                        .host
                        .take_session(channel.id)
                        .ok_or(NetworkError::State)?;
                    let lease = SessionLease::new(session, now_ms)?;
                    channel.reader =
                        FrameReader::new(FrameMode::Authenticated, now_ms, lease.expires_ms())?;
                    channel.lease = Some(lease);
                    channel.after_write = AfterWrite::Data;
                    return Ok(PhoneEvent::Paired {
                        id: channel.id.value(),
                    });
                }
                AfterWrite::Handshake => {
                    channel.reader = FrameReader::new(
                        FrameMode::Handshake,
                        now_ms,
                        self.host.deadline_ms().ok_or(NetworkError::State)?,
                    )?
                }
                AfterWrite::Data => {
                    channel.reader = FrameReader::new(
                        FrameMode::Authenticated,
                        now_ms,
                        channel
                            .lease
                            .as_ref()
                            .ok_or(NetworkError::State)?
                            .expires_ms(),
                    )?
                }
            }
            return Ok(PhoneEvent::Pending);
        }
        if channel.reader.poll_read(&mut channel.socket, now_ms)? == ReadStatus::Pending {
            return Ok(PhoneEvent::Pending);
        }
        let bytes = channel.reader.frame().ok_or(NetworkError::State)?;
        if let Some(lease) = &mut channel.lease {
            let frame = lease
                .session_mut(now_ms)?
                .open(Transport::Tcp, bytes)?
                .frame;
            match frame {
                Frame::Disconnect(_) => {
                    return Ok(PhoneEvent::Closed {
                        id: channel.id.value(),
                    });
                }
                Frame::Ping(ping) => {
                    let us = now_ms
                        .checked_mul(1000)
                        .ok_or(ProtocolError::ClockRegression)?;
                    let pong = Frame::Pong(PongPayload {
                        ping_id: ping.ping_id,
                        echo_time_us: ping.sent_time_us,
                        received_time_us: us,
                        sent_time_us: us,
                    });
                    let bytes = lease.session_mut(now_ms)?.seal(Transport::Tcp, &pong)?;
                    channel.writer.queue(
                        FrameMode::Authenticated,
                        &bytes,
                        now_ms,
                        lease.expires_ms(),
                    )?;
                    channel.after_write = AfterWrite::Data;
                }
                other => {
                    channel
                        .reader
                        .rearm(FrameMode::Authenticated, now_ms, lease.expires_ms())?;
                    return Ok(PhoneEvent::Frame(other));
                }
            }
        } else {
            let message = PairingMessage::decode(bytes)?;
            match self.host.receive(channel.id, &message, now_ms)? {
                HostEvent::ConsentRequested => {
                    let label = self
                        .host
                        .consent_request(channel.id)
                        .ok_or(NetworkError::State)?
                        .desktop_label
                        .clone();
                    channel.reader.rearm(
                        FrameMode::Handshake,
                        now_ms,
                        self.host.deadline_ms().ok_or(NetworkError::State)?,
                    )?;
                    return Ok(PhoneEvent::Consent {
                        id: channel.id.value(),
                        label,
                        address: channel.socket.peer_addr()?,
                    });
                }
                HostEvent::Reply(reply) => {
                    channel.writer.queue(
                        FrameMode::Handshake,
                        &reply.encode()?,
                        now_ms,
                        self.host.deadline_ms().ok_or(NetworkError::State)?,
                    )?;
                    channel.after_write = AfterWrite::Handshake;
                }
                HostEvent::Ready(ready) => {
                    channel.writer.queue(
                        FrameMode::Authenticated,
                        &ready,
                        now_ms,
                        self.host.deadline_ms().ok_or(NetworkError::State)?,
                    )?;
                    channel.after_write = AfterWrite::Ready;
                }
                HostEvent::Cancelled => {
                    return Ok(PhoneEvent::Closed {
                        id: channel.id.value(),
                    });
                }
                HostEvent::RetryReady => channel.reader.rearm(
                    FrameMode::Handshake,
                    now_ms,
                    self.host.deadline_ms().ok_or(NetworkError::State)?,
                )?,
            }
        }
        Ok(PhoneEvent::Pending)
    }
}
impl Drop for PhonePairingServer {
    fn drop(&mut self) {
        self.stop()
    }
}

pub enum DesktopEvent {
    Pending,
    EnterCode,
    WrongCode,
    Paired,
    Frame(Frame),
}
#[derive(Clone, Copy)]
enum ClientNext {
    Accept,
    Code,
    B,
    Ready,
}
enum ClientPhase {
    Writing(ClientNext),
    Accept,
    Code,
    B,
    Ready,
    Paired,
    Closed,
}
pub struct DesktopPairingClient {
    socket: TcpStream,
    handshake: DesktopHandshake,
    reader: FrameReader,
    writer: FrameWriter,
    phase: ClientPhase,
    attempts: u8,
    lease: Option<SessionLease>,
}
impl DesktopPairingClient {
    pub fn connect(address: SocketAddr, label: &str, now_ms: u64) -> Result<Self, NetworkError> {
        let socket = TcpStream::connect_timeout(&address, Duration::from_secs(3))?;
        Self::from_socket(socket, label, now_ms)
    }
    pub fn from_socket(socket: TcpStream, label: &str, now_ms: u64) -> Result<Self, NetworkError> {
        configure(&socket)?;
        let handshake = DesktopHandshake::new(label)?;
        let mut writer = FrameWriter::new(now_ms);
        writer.queue(
            FrameMode::Handshake,
            &handshake.request().encode()?,
            now_ms,
            now_ms.saturating_add(3000),
        )?;
        Ok(Self {
            socket,
            handshake,
            reader: FrameReader::new(FrameMode::Handshake, now_ms, now_ms.saturating_add(33_000))?,
            writer,
            phase: ClientPhase::Writing(ClientNext::Accept),
            attempts: 0,
            lease: None,
        })
    }
    pub fn code_deadline_ms(&self) -> Option<u64> {
        self.handshake.deadline_ms()
    }
    pub fn enter_code(&mut self, code: &str, now_ms: u64) -> Result<(), NetworkError> {
        if !matches!(self.phase, ClientPhase::Code) {
            return Err(NetworkError::State);
        }
        let a = self.handshake.start_attempt(code, now_ms)?;
        self.attempts += 1;
        self.writer.queue(
            FrameMode::Handshake,
            &a.encode()?,
            now_ms,
            self.handshake.deadline_ms().ok_or(NetworkError::State)?,
        )?;
        self.phase = ClientPhase::Writing(ClientNext::B);
        Ok(())
    }
    pub fn poll(&mut self, now_ms: u64) -> Result<DesktopEvent, NetworkError> {
        let result = self.poll_inner(now_ms);
        if result.is_err() {
            self.close();
        }
        result
    }
    fn poll_inner(&mut self, now_ms: u64) -> Result<DesktopEvent, NetworkError> {
        if matches!(self.phase, ClientPhase::Closed) {
            return Err(NetworkError::State);
        }
        if let Some(lease) = &mut self.lease {
            lease.check_live(now_ms)?;
        }
        if let ClientPhase::Writing(next) = self.phase {
            if self.writer.poll_write(&mut self.socket, now_ms)? == WriteStatus::Pending {
                return Ok(DesktopEvent::Pending);
            }
            let (mode, deadline) = match next {
                ClientNext::Accept => (FrameMode::Handshake, now_ms.saturating_add(33_000)),
                ClientNext::Code => (
                    FrameMode::Handshake,
                    self.handshake.deadline_ms().ok_or(NetworkError::State)?,
                ),
                ClientNext::B => (
                    FrameMode::Handshake,
                    now_ms
                        .saturating_add(3000)
                        .min(self.handshake.deadline_ms().ok_or(NetworkError::State)?),
                ),
                ClientNext::Ready => (
                    FrameMode::Authenticated,
                    now_ms
                        .saturating_add(3000)
                        .min(self.handshake.deadline_ms().ok_or(NetworkError::State)?),
                ),
            };
            self.reader = FrameReader::new(mode, now_ms, deadline)?;
            self.phase = match next {
                ClientNext::Accept => ClientPhase::Accept,
                ClientNext::Code => ClientPhase::Code,
                ClientNext::B => ClientPhase::B,
                ClientNext::Ready => ClientPhase::Ready,
            };
            return Ok(if matches!(next, ClientNext::Code) {
                DesktopEvent::EnterCode
            } else {
                DesktopEvent::Pending
            });
        }
        if matches!(self.phase, ClientPhase::Code) {
            if now_ms >= self.handshake.deadline_ms().ok_or(NetworkError::State)? {
                return Err(ProtocolError::PairingTokenExpired.into());
            }
            return Ok(DesktopEvent::Pending);
        }
        if matches!(self.phase, ClientPhase::Paired) && self.writer.is_pending() {
            self.writer.poll_write(&mut self.socket, now_ms)?;
            return Ok(DesktopEvent::Pending);
        }
        if self.reader.poll_read(&mut self.socket, now_ms)? == ReadStatus::Pending {
            return Ok(DesktopEvent::Pending);
        }
        let bytes = self.reader.frame().ok_or(NetworkError::State)?;
        match self.phase {
            ClientPhase::Accept => {
                self.handshake
                    .accept(&PairingMessage::decode(bytes)?, now_ms)?;
                self.phase = ClientPhase::Code;
                Ok(DesktopEvent::EnterCode)
            }
            ClientPhase::B => {
                match self
                    .handshake
                    .handle_pake_b(&PairingMessage::decode(bytes)?, now_ms)
                {
                    Ok(ca) => {
                        self.writer.queue(
                            FrameMode::Handshake,
                            &ca.encode()?,
                            now_ms,
                            self.handshake.deadline_ms().ok_or(NetworkError::State)?,
                        )?;
                        self.phase = ClientPhase::Writing(ClientNext::Ready);
                        Ok(DesktopEvent::Pending)
                    }
                    Err(ProtocolError::PakeFailed) if self.attempts < 3 => {
                        let retry = PairingMessage::Retry {
                            request_id: *self.handshake.request().request_id(),
                        };
                        self.writer.queue(
                            FrameMode::Handshake,
                            &retry.encode()?,
                            now_ms,
                            self.handshake.deadline_ms().ok_or(NetworkError::State)?,
                        )?;
                        self.phase = ClientPhase::Writing(ClientNext::Code);
                        Ok(DesktopEvent::WrongCode)
                    }
                    Err(e) => Err(e.into()),
                }
            }
            ClientPhase::Ready => {
                let session = self.handshake.finish(bytes, now_ms)?;
                let lease = SessionLease::new(session, now_ms)?;
                self.reader =
                    FrameReader::new(FrameMode::Authenticated, now_ms, lease.expires_ms())?;
                self.lease = Some(lease);
                self.phase = ClientPhase::Paired;
                Ok(DesktopEvent::Paired)
            }
            ClientPhase::Paired => {
                let lease = self.lease.as_mut().ok_or(NetworkError::State)?;
                let frame = lease
                    .session_mut(now_ms)?
                    .open(Transport::Tcp, bytes)?
                    .frame;
                self.reader
                    .rearm(FrameMode::Authenticated, now_ms, lease.expires_ms())?;
                Ok(DesktopEvent::Frame(frame))
            }
            _ => Err(NetworkError::State),
        }
    }
    pub fn send(&mut self, frame: &Frame, now_ms: u64) -> Result<(), NetworkError> {
        if !matches!(self.phase, ClientPhase::Paired) || self.writer.is_pending() {
            return Err(NetworkError::State);
        }
        let lease = self.lease.as_mut().ok_or(NetworkError::State)?;
        let bytes = lease.session_mut(now_ms)?.seal(Transport::Tcp, frame)?;
        self.writer
            .queue(FrameMode::Authenticated, &bytes, now_ms, lease.expires_ms())?;
        Ok(())
    }
    pub fn close(&mut self) {
        self.handshake.cancel();
        self.lease = None;
        self.reader.close();
        self.writer.close();
        self.phase = ClientPhase::Closed;
        let _ = self.socket.shutdown(Shutdown::Both);
    }
    /// Transfer session ownership once, closing the old TCP channel. Transport
    /// setup and candidate confirmation use the shared Resumption state machine.
    pub fn detach_session(&mut self, now_ms: u64) -> Result<SessionLease, NetworkError> {
        if !matches!(self.phase, ClientPhase::Paired) || self.writer.is_pending() {
            return Err(NetworkError::State);
        }
        self.lease
            .as_mut()
            .ok_or(NetworkError::State)?
            .check_live(now_ms)?;
        let lease = self.lease.take().ok_or(NetworkError::State)?;
        self.close();
        Ok(lease)
    }
}
impl Drop for DesktopPairingClient {
    fn drop(&mut self) {
        self.close()
    }
}
fn configure(socket: &TcpStream) -> Result<(), NetworkError> {
    socket.set_nonblocking(true)?;
    socket.set_nodelay(true)?;
    Ok(())
}
impl std::fmt::Debug for PhonePairingServer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("PhonePairingServer([redacted])")
    }
}
impl std::fmt::Debug for DesktopPairingClient {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("DesktopPairingClient([redacted])")
    }
}
