//! Fixed-buffer, nonblocking TCP framing for the pairing/control channel.
//!
//! Each poll performs at most one read or write. Callers supply a monotonic
//! clock, arm the stage deadline, and poll timers even without socket activity.
//! Use nonblocking sockets: this module does not run an executor or change OS
//! socket options. No frame length causes a peer-sized allocation.

use std::io::{self, Read, Write};

use crate::frame::{HEADER_LEN, MAX_FRAME_LEN, TAG_LEN};
use crate::{MAX_HANDSHAKE_FRAME_LEN, ProtocolError};

use super::wire::preauth_body_len;

/// Absolute time budget for a partially received frame or queued write.
/// Receiving another byte does not extend this budget.
pub const FRAME_PROGRESS_TIMEOUT_MS: u64 = 3_000;
pub const TCP_PREFIX_LEN: usize = 2;
pub const MAX_AUTHENTICATED_TCP_FRAME_LEN: usize = TCP_PREFIX_LEN + MAX_FRAME_LEN;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrameMode {
    Handshake,
    Authenticated,
}

impl FrameMode {
    pub fn body_len(self, prefix: [u8; 2]) -> Result<usize, ProtocolError> {
        if self == Self::Handshake {
            return preauth_body_len(prefix);
        }
        let length = u16::from_be_bytes(prefix) as usize;
        if length < HEADER_LEN + TAG_LEN {
            return Err(ProtocolError::TruncatedFrame {
                len: length,
                minimum: HEADER_LEN + TAG_LEN,
            });
        }
        if length > MAX_FRAME_LEN {
            return Err(ProtocolError::OversizedFrame {
                len: length,
                maximum: MAX_FRAME_LEN,
            });
        }
        Ok(length)
    }

    pub fn validate(self, bytes: &[u8]) -> Result<(), ProtocolError> {
        if bytes.len() < TCP_PREFIX_LEN {
            return Err(ProtocolError::TruncatedFrame {
                len: bytes.len(),
                minimum: TCP_PREFIX_LEN,
            });
        }
        let body_len = self.body_len([bytes[0], bytes[1]])?;
        if bytes.len() != TCP_PREFIX_LEN + body_len {
            return Err(ProtocolError::InvalidLength {
                frame_type: 0,
                len: bytes.len(),
            });
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TransportError {
    Protocol(ProtocolError),
    DeadlineExpired,
    ClockRegression,
    TimeOverflow,
    PeerClosed,
    Io(io::ErrorKind),
    /// A completed read must be consumed/rearmed; a queued write cannot be replaced.
    Busy,
    /// A failed/closed framer cannot be reused for another connection.
    Closed,
}

impl std::fmt::Display for TransportError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Protocol(error) => error.fmt(f),
            Self::DeadlineExpired => f.write_str("TCP frame deadline expired"),
            Self::ClockRegression => f.write_str("monotonic TCP clock moved backwards"),
            Self::TimeOverflow => f.write_str("TCP deadline overflow"),
            Self::PeerClosed => f.write_str("TCP peer closed the connection"),
            Self::Io(kind) => write!(f, "TCP I/O failed ({kind:?})"),
            Self::Busy => f.write_str("TCP frame slot is occupied"),
            Self::Closed => f.write_str("TCP framer is closed"),
        }
    }
}

impl std::error::Error for TransportError {}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReadStatus {
    Pending,
    Complete,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WriteStatus {
    Pending,
    Complete,
}

/// One frame of receive storage, including the outer prefix.
/// Debug deliberately excludes all frame contents.
pub struct FrameReader {
    bytes: [u8; MAX_HANDSHAKE_FRAME_LEN],
    received: usize,
    target: usize,
    mode: FrameMode,
    deadline_ms: u64,
    last_now_ms: u64,
    started: bool,
    complete: bool,
    closed: bool,
}

impl FrameReader {
    pub fn new(mode: FrameMode, now_ms: u64, deadline_ms: u64) -> Result<Self, TransportError> {
        if now_ms >= deadline_ms {
            return Err(TransportError::DeadlineExpired);
        }
        Ok(Self {
            bytes: [0; MAX_HANDSHAKE_FRAME_LEN],
            received: 0,
            target: TCP_PREFIX_LEN,
            mode,
            deadline_ms,
            last_now_ms: now_ms,
            started: false,
            complete: false,
            closed: false,
        })
    }

    /// Returns a complete frame. It remains valid until rearm/close.
    pub fn frame(&self) -> Option<&[u8]> {
        self.complete.then_some(&self.bytes[..self.received])
    }
    pub fn is_idle(&self) -> bool {
        !self.closed && !self.started && !self.complete
    }

    pub const fn deadline_ms(&self) -> u64 {
        self.deadline_ms
    }

    /// Call after consuming a complete frame. Coalesced next-frame bytes stay
    /// in the socket because reads never extend beyond the current frame.
    pub fn rearm(
        &mut self,
        mode: FrameMode,
        now_ms: u64,
        deadline_ms: u64,
    ) -> Result<(), TransportError> {
        if self.closed {
            return Err(TransportError::Closed);
        }
        if !self.complete {
            return Err(TransportError::Busy);
        }
        self.check_deadline(now_ms)?;
        if now_ms >= deadline_ms {
            return self.fail(TransportError::DeadlineExpired);
        }
        self.bytes[..self.received].fill(0);
        self.received = 0;
        self.target = TCP_PREFIX_LEN;
        self.mode = mode;
        self.deadline_ms = deadline_ms;
        self.started = false;
        self.complete = false;
        Ok(())
    }

    /// Poll at most one nonblocking read, validating the prefix before reading
    /// any body bytes. EOF, invalid lengths, clock failures, and timeout close
    /// and erase the reader; the caller must also close/cancel its connection.
    pub fn poll_read(
        &mut self,
        stream: &mut impl Read,
        now_ms: u64,
    ) -> Result<ReadStatus, TransportError> {
        self.check_deadline(now_ms)?;
        if self.complete {
            return Err(TransportError::Busy);
        }
        match stream.read(&mut self.bytes[self.received..self.target]) {
            Ok(0) => self.fail(TransportError::PeerClosed),
            Ok(count) => {
                if !self.started {
                    let Some(progress_deadline) = now_ms.checked_add(FRAME_PROGRESS_TIMEOUT_MS)
                    else {
                        return self.fail(TransportError::TimeOverflow);
                    };
                    self.deadline_ms = self.deadline_ms.min(progress_deadline);
                    self.started = true;
                }
                self.received += count;
                if self.received == TCP_PREFIX_LEN && self.target == TCP_PREFIX_LEN {
                    let body_len = match self.mode.body_len([self.bytes[0], self.bytes[1]]) {
                        Ok(length) => length,
                        Err(error) => return self.fail(TransportError::Protocol(error)),
                    };
                    self.target = TCP_PREFIX_LEN + body_len;
                }
                if self.received == self.target {
                    self.complete = true;
                    Ok(ReadStatus::Complete)
                } else {
                    Ok(ReadStatus::Pending)
                }
            }
            Err(error) if retryable(error.kind()) => Ok(ReadStatus::Pending),
            Err(error) => self.fail(TransportError::Io(error.kind())),
        }
    }

    /// Timer entry point: deadlines must run even when the peer sends nothing.
    pub fn check_deadline(&mut self, now_ms: u64) -> Result<(), TransportError> {
        if self.closed {
            return Err(TransportError::Closed);
        }
        self.check_clock(now_ms)?;
        if now_ms >= self.deadline_ms {
            return self.fail(TransportError::DeadlineExpired);
        }
        Ok(())
    }

    pub fn close(&mut self) {
        self.bytes.fill(0);
        self.received = 0;
        self.complete = false;
        self.closed = true;
    }

    fn check_clock(&mut self, now_ms: u64) -> Result<(), TransportError> {
        if now_ms < self.last_now_ms {
            return self.fail(TransportError::ClockRegression);
        }
        self.last_now_ms = now_ms;
        Ok(())
    }

    fn fail<T>(&mut self, error: TransportError) -> Result<T, TransportError> {
        self.close();
        Err(error)
    }
}

/// A single bounded pending write. The caller seals a frame once, then retains
/// these exact bytes across short writes; retries never reseal/reset counters.
pub struct FrameWriter {
    bytes: [u8; MAX_HANDSHAKE_FRAME_LEN],
    length: usize,
    sent: usize,
    deadline_ms: u64,
    last_now_ms: u64,
    closed: bool,
}

impl FrameWriter {
    pub const fn new(now_ms: u64) -> Self {
        Self {
            bytes: [0; MAX_HANDSHAKE_FRAME_LEN],
            length: 0,
            sent: 0,
            deadline_ms: 0,
            last_now_ms: now_ms,
            closed: false,
        }
    }

    pub const fn is_pending(&self) -> bool {
        self.length != 0
    }

    pub fn deadline_ms(&self) -> Option<u64> {
        self.is_pending().then_some(self.deadline_ms)
    }

    pub fn queue(
        &mut self,
        mode: FrameMode,
        bytes: &[u8],
        now_ms: u64,
        stage_deadline_ms: u64,
    ) -> Result<(), TransportError> {
        self.check_deadline(now_ms)?;
        if self.is_pending() {
            return Err(TransportError::Busy);
        }
        if let Err(error) = mode.validate(bytes) {
            return self.fail(TransportError::Protocol(error));
        }
        let Some(progress_deadline) = now_ms.checked_add(FRAME_PROGRESS_TIMEOUT_MS) else {
            return self.fail(TransportError::TimeOverflow);
        };
        self.deadline_ms = stage_deadline_ms.min(progress_deadline);
        if now_ms >= self.deadline_ms {
            return self.fail(TransportError::DeadlineExpired);
        }
        self.bytes[..bytes.len()].copy_from_slice(bytes);
        self.length = bytes.len();
        self.sent = 0;
        Ok(())
    }

    pub fn poll_write(
        &mut self,
        stream: &mut impl Write,
        now_ms: u64,
    ) -> Result<WriteStatus, TransportError> {
        self.check_deadline(now_ms)?;
        if !self.is_pending() {
            return Ok(WriteStatus::Complete);
        }
        match stream.write(&self.bytes[self.sent..self.length]) {
            Ok(0) => self.fail(TransportError::PeerClosed),
            Ok(count) => {
                self.sent += count;
                if self.sent == self.length {
                    self.bytes[..self.length].fill(0);
                    self.length = 0;
                    self.sent = 0;
                    Ok(WriteStatus::Complete)
                } else {
                    Ok(WriteStatus::Pending)
                }
            }
            Err(error) if retryable(error.kind()) => Ok(WriteStatus::Pending),
            Err(error) => self.fail(TransportError::Io(error.kind())),
        }
    }

    pub fn check_deadline(&mut self, now_ms: u64) -> Result<(), TransportError> {
        if self.closed {
            return Err(TransportError::Closed);
        }
        if now_ms < self.last_now_ms {
            return self.fail(TransportError::ClockRegression);
        }
        self.last_now_ms = now_ms;
        if self.is_pending() && now_ms >= self.deadline_ms {
            return self.fail(TransportError::DeadlineExpired);
        }
        Ok(())
    }

    pub fn close(&mut self) {
        self.bytes.fill(0);
        self.length = 0;
        self.sent = 0;
        self.closed = true;
    }

    fn fail<T>(&mut self, error: TransportError) -> Result<T, TransportError> {
        self.close();
        Err(error)
    }
}

impl std::fmt::Debug for FrameReader {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("FrameReader")
            .field("mode", &self.mode)
            .field("closed", &self.closed)
            .finish_non_exhaustive()
    }
}

impl std::fmt::Debug for FrameWriter {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("FrameWriter")
            .field("pending", &self.is_pending())
            .field("closed", &self.closed)
            .finish_non_exhaustive()
    }
}

fn retryable(kind: io::ErrorKind) -> bool {
    matches!(kind, io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted)
}
