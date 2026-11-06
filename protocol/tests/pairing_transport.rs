//! Transport/admission failure tests, including a real loopback TCP exchange.
//! Consent is an explicit test action; no Android UI or gamepad is attached.

use std::io::{self, Cursor, Read, Write};
use std::net::{IpAddr, Ipv4Addr, Shutdown, TcpListener, TcpStream};
use std::time::Instant;

use padlink_protocol::ProtocolError;
use padlink_protocol::crypto::{
    Direction, KeyDomain, ReplayWindow, SessionId, SessionSecret, TrafficKey, Transport,
};
use padlink_protocol::frame::{Frame, PingPayload};
use padlink_protocol::pairing::host::{
    ConnectionId, HostError, HostEvent, HostState, PhonePairingHost,
};
use padlink_protocol::pairing::transport::{
    FrameMode, FrameReader, FrameWriter, ReadStatus, TransportError, WriteStatus,
};
use padlink_protocol::pairing::{DesktopHandshake, PairingMessage};
use zeroize::Zeroizing;

fn source(octet: u8) -> IpAddr {
    IpAddr::V4(Ipv4Addr::new(192, 0, 2, octet))
}

fn awaiting_consent(
    host: &mut PhonePairingHost,
    desktop: &DesktopHandshake,
    now: u64,
) -> ConnectionId {
    let id = host.begin_connection(source(1), now).unwrap();
    assert!(matches!(
        host.receive(id, &desktop.request(), now).unwrap(),
        HostEvent::ConsentRequested
    ));
    id
}

fn consented() -> (
    PhonePairingHost,
    ConnectionId,
    DesktopHandshake,
    Zeroizing<String>,
) {
    let mut host = PhonePairingHost::new(0);
    let mut desktop = DesktopHandshake::new("Unverified desktop").unwrap();
    let id = awaiting_consent(&mut host, &desktop, 0);
    desktop.accept(&host.allow(id, 0).unwrap(), 0).unwrap();
    let code = Zeroizing::new(host.display_code(id, 0).unwrap().to_owned());
    (host, id, desktop, code)
}

fn ready_pending() -> (PhonePairingHost, ConnectionId, DesktopHandshake, Vec<u8>) {
    let (mut host, id, mut desktop, code) = consented();
    let a = desktop.start_attempt(&code, 1).unwrap();
    let HostEvent::Reply(b) = host.receive(id, &a, 2).unwrap() else {
        panic!("PakeB")
    };
    let ca = desktop.handle_pake_b(&b, 3).unwrap();
    let HostEvent::Ready(ready) = host.receive(id, &ca, 4).unwrap() else {
        panic!("ready")
    };
    (host, id, desktop, ready)
}

struct Chunked<T> {
    inner: T,
    chunk: usize,
    calls: usize,
}

impl<T: Read> Read for Chunked<T> {
    fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        self.calls += 1;
        let length = bytes.len().min(self.chunk);
        self.inner.read(&mut bytes[..length])
    }
}

impl<T: Write> Write for Chunked<T> {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.calls += 1;
        self.inner.write(&bytes[..bytes.len().min(self.chunk)])
    }
    fn flush(&mut self) -> io::Result<()> {
        self.inner.flush()
    }
}

struct Fault(io::ErrorKind, usize);
impl Read for Fault {
    fn read(&mut self, _: &mut [u8]) -> io::Result<usize> {
        self.1 += 1;
        Err(self.0.into())
    }
}
impl Write for Fault {
    fn write(&mut self, _: &[u8]) -> io::Result<usize> {
        self.1 += 1;
        Err(self.0.into())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

fn request_bytes() -> Vec<u8> {
    DesktopHandshake::new("Desktop")
        .unwrap()
        .request()
        .encode()
        .unwrap()
}

#[test]
fn fragmented_frames_use_one_read_per_poll_and_keep_coalesced_frames_separate() {
    let bytes = request_bytes();
    for chunk in [1, 2, 3, 7, 4096] {
        let mut reader = FrameReader::new(FrameMode::Handshake, 0, 60_000).unwrap();
        let mut input = Chunked {
            inner: Cursor::new([bytes.as_slice(), bytes.as_slice()].concat()),
            chunk,
            calls: 0,
        };
        for expected in 1..=2 {
            loop {
                let before = input.calls;
                let status = reader.poll_read(&mut input, 1).unwrap();
                assert_eq!(input.calls, before + 1);
                if status == ReadStatus::Complete {
                    break;
                }
            }
            assert_eq!(reader.frame().unwrap(), bytes);
            assert_eq!(input.inner.position(), (expected * bytes.len()) as u64);
            if expected == 1 {
                reader.rearm(FrameMode::Handshake, 1, 60_000).unwrap();
            }
        }
    }
}

#[test]
fn invalid_prefix_is_rejected_before_any_body_read() {
    for length in [0_u16, 1, 4095, u16::MAX] {
        let mut input = Cursor::new([length.to_be_bytes().as_slice(), &[0; 32]].concat());
        let mut reader = FrameReader::new(FrameMode::Handshake, 0, 3000).unwrap();
        assert!(matches!(
            reader.poll_read(&mut input, 1),
            Err(TransportError::Protocol(_))
        ));
        assert_eq!(input.position(), 2);
        assert!(reader.frame().is_none());
        assert_eq!(reader.poll_read(&mut input, 2), Err(TransportError::Closed));
    }
}

#[test]
fn maximum_frame_boundaries_are_exact_in_both_modes() {
    for (mode, accepted, rejected) in [
        (FrameMode::Handshake, 4094_u16, 4095_u16),
        (FrameMode::Authenticated, 256, 257),
    ] {
        let bytes = [
            accepted.to_be_bytes().as_slice(),
            vec![0; accepted as usize].as_slice(),
        ]
        .concat();
        let mut input = Cursor::new(&bytes);
        let mut reader = FrameReader::new(mode, 0, 3000).unwrap();
        assert_eq!(
            reader.poll_read(&mut input, 0).unwrap(),
            ReadStatus::Pending
        );
        assert_eq!(
            reader.poll_read(&mut input, 0).unwrap(),
            ReadStatus::Complete
        );
        assert_eq!(reader.frame().unwrap(), bytes);
        assert!(mode.body_len(rejected.to_be_bytes()).is_err());
    }
    assert!(
        FrameMode::Authenticated
            .body_len(27_u16.to_be_bytes())
            .is_err()
    );
    assert_eq!(
        FrameMode::Authenticated
            .body_len(28_u16.to_be_bytes())
            .unwrap(),
        28
    );
}

#[test]
fn slow_drip_does_not_extend_the_absolute_read_deadline() {
    let mut input = Chunked {
        inner: Cursor::new(request_bytes()),
        chunk: 1,
        calls: 0,
    };
    let mut reader = FrameReader::new(FrameMode::Handshake, 0, 60_000).unwrap();
    reader.poll_read(&mut input, 100).unwrap();
    assert_eq!(reader.deadline_ms(), 3100);
    reader.poll_read(&mut input, 2000).unwrap();
    reader.poll_read(&mut input, 3099).unwrap();
    assert_eq!(reader.deadline_ms(), 3100);
    let calls = input.calls;
    assert_eq!(
        reader.poll_read(&mut input, 3100),
        Err(TransportError::DeadlineExpired)
    );
    assert_eq!(input.calls, calls);
    assert!(reader.frame().is_none());
}

#[test]
fn no_traffic_still_expires_at_the_stage_deadline() {
    let mut input = Fault(io::ErrorKind::WouldBlock, 0);
    let mut reader = FrameReader::new(FrameMode::Handshake, 0, 3000).unwrap();
    assert_eq!(
        reader.poll_read(&mut input, 2999).unwrap(),
        ReadStatus::Pending
    );
    assert_eq!(
        reader.check_deadline(3000),
        Err(TransportError::DeadlineExpired)
    );
    assert_eq!(reader.check_deadline(3001), Err(TransportError::Closed));
    assert_eq!(input.1, 1);
}

#[test]
fn eof_and_truncated_body_close_the_reader() {
    let bytes = request_bytes();
    for cut in [0, 1, 2, 4, bytes.len() - 1] {
        let mut input = Cursor::new(&bytes[..cut]);
        let mut reader = FrameReader::new(FrameMode::Handshake, 0, 3000).unwrap();
        loop {
            match reader.poll_read(&mut input, 1) {
                Ok(ReadStatus::Pending) => {}
                Err(TransportError::PeerClosed) => break,
                outcome => panic!("unexpected {outcome:?}"),
            }
        }
        assert!(reader.frame().is_none());
        assert_eq!(reader.check_deadline(1), Err(TransportError::Closed));
    }
}

#[test]
fn completed_read_cannot_be_overwritten_or_rearmed_after_expiry() {
    let mut input = Cursor::new(request_bytes());
    let mut reader = FrameReader::new(FrameMode::Handshake, 0, 3000).unwrap();
    assert_eq!(
        reader.rearm(FrameMode::Handshake, 0, 3000),
        Err(TransportError::Busy)
    );
    reader.poll_read(&mut input, 1).unwrap();
    reader.poll_read(&mut input, 1).unwrap();
    assert_eq!(reader.poll_read(&mut input, 2), Err(TransportError::Busy));
    assert_eq!(
        reader.rearm(FrameMode::Authenticated, 3000, 60_000),
        Err(TransportError::DeadlineExpired)
    );
    assert!(reader.frame().is_none());
}

#[test]
fn short_writes_preserve_exact_bytes_and_bound_each_poll() {
    let bytes = request_bytes();
    let mut writer = FrameWriter::new(0);
    let mut output = Chunked {
        inner: Vec::new(),
        chunk: 1,
        calls: 0,
    };
    writer
        .queue(FrameMode::Handshake, &bytes, 0, 60_000)
        .unwrap();
    assert_eq!(
        writer.queue(FrameMode::Handshake, &bytes, 1, 60_000),
        Err(TransportError::Busy)
    );
    loop {
        let before = output.calls;
        let status = writer.poll_write(&mut output, 1).unwrap();
        assert_eq!(output.calls, before + 1);
        if status == WriteStatus::Complete {
            break;
        }
    }
    assert_eq!(output.inner, bytes);
    assert!(!writer.is_pending());
    assert_eq!(writer.deadline_ms(), None);
    assert_eq!(
        writer.poll_write(&mut output, 2).unwrap(),
        WriteStatus::Complete
    );
}

#[test]
fn stalled_and_slow_writes_expire_without_deadline_extension() {
    let bytes = request_bytes();
    let mut writer = FrameWriter::new(0);
    let mut output = Chunked {
        inner: Vec::new(),
        chunk: 1,
        calls: 0,
    };
    writer
        .queue(FrameMode::Handshake, &bytes, 10, 60_000)
        .unwrap();
    writer.poll_write(&mut output, 100).unwrap();
    writer.poll_write(&mut output, 3009).unwrap();
    assert_eq!(writer.deadline_ms(), Some(3010));
    assert_eq!(
        writer.poll_write(&mut output, 3010),
        Err(TransportError::DeadlineExpired)
    );
    assert_eq!(output.inner.len(), 2);
    assert!(!writer.is_pending());
    assert_eq!(
        writer.queue(FrameMode::Handshake, &bytes, 3011, 60_000),
        Err(TransportError::Closed)
    );

    let mut writer = FrameWriter::new(0);
    writer.queue(FrameMode::Handshake, &bytes, 0, 100).unwrap();
    let mut blocked = Fault(io::ErrorKind::WouldBlock, 0);
    assert_eq!(
        writer.poll_write(&mut blocked, 99).unwrap(),
        WriteStatus::Pending
    );
    assert_eq!(
        writer.check_deadline(100),
        Err(TransportError::DeadlineExpired)
    );
}

#[test]
fn interrupted_io_yields_instead_of_spinning_and_other_errors_close() {
    for kind in [
        io::ErrorKind::Interrupted,
        io::ErrorKind::WouldBlock,
        io::ErrorKind::ConnectionReset,
    ] {
        let mut io = Fault(kind, 0);
        let mut reader = FrameReader::new(FrameMode::Handshake, 0, 3000).unwrap();
        let read = reader.poll_read(&mut io, 1);
        assert_eq!(io.1, 1);
        let mut writer = FrameWriter::new(0);
        writer
            .queue(FrameMode::Handshake, &request_bytes(), 0, 3000)
            .unwrap();
        let write = writer.poll_write(&mut io, 1);
        assert_eq!(io.1, 2);
        if kind == io::ErrorKind::ConnectionReset {
            assert_eq!(read, Err(TransportError::Io(kind)));
            assert_eq!(write, Err(TransportError::Io(kind)));
            assert!(!writer.is_pending());
        } else {
            assert_eq!(read.unwrap(), ReadStatus::Pending);
            assert_eq!(write.unwrap(), WriteStatus::Pending);
        }
    }
}

#[test]
fn invalid_write_length_and_zero_write_fail_closed() {
    let mut writer = FrameWriter::new(0);
    assert!(matches!(
        writer.queue(FrameMode::Handshake, &[0, 2, 1], 0, 3000),
        Err(TransportError::Protocol(_))
    ));
    assert!(!writer.is_pending());
    let mut writer = FrameWriter::new(0);
    writer
        .queue(FrameMode::Handshake, &request_bytes(), 0, 3000)
        .unwrap();
    let mut empty = Cursor::new(&mut [][..]);
    assert_eq!(
        writer.poll_write(&mut empty, 1),
        Err(TransportError::PeerClosed)
    );
    assert!(!writer.is_pending());
}

#[test]
fn transport_clock_regression_and_deadline_overflow_fail_closed() {
    let mut reader = FrameReader::new(FrameMode::Handshake, 10, 3000).unwrap();
    assert_eq!(
        reader.check_deadline(9),
        Err(TransportError::ClockRegression)
    );
    let mut writer = FrameWriter::new(10);
    assert_eq!(
        writer.queue(FrameMode::Handshake, &request_bytes(), 9, 3000),
        Err(TransportError::ClockRegression)
    );
    let mut writer = FrameWriter::new(u64::MAX - 10);
    assert_eq!(
        writer.queue(
            FrameMode::Handshake,
            &request_bytes(),
            u64::MAX - 10,
            u64::MAX
        ),
        Err(TransportError::TimeOverflow)
    );
    let mut reader = FrameReader::new(FrameMode::Handshake, u64::MAX - 10, u64::MAX).unwrap();
    assert_eq!(
        reader.poll_read(&mut Cursor::new(request_bytes()), u64::MAX - 10),
        Err(TransportError::TimeOverflow)
    );
}

#[test]
fn framing_debug_output_does_not_include_frame_contents() {
    let bytes = request_bytes();
    let mut reader = FrameReader::new(FrameMode::Handshake, 0, 3000).unwrap();
    let mut input = Cursor::new(&bytes);
    reader.poll_read(&mut input, 0).unwrap();
    reader.poll_read(&mut input, 0).unwrap();
    let mut writer = FrameWriter::new(0);
    writer.queue(FrameMode::Handshake, &bytes, 0, 3000).unwrap();
    let text = format!("{reader:?} {writer:?}");
    assert!(!text.contains("Desktop"));
    assert!(!text.contains(&format!("{bytes:?}")));
}

fn tcp_key() -> TrafficKey {
    TrafficKey::derive(
        &SessionSecret::from_bytes([7; 32]),
        SessionId::from_bytes([8; 16]),
        KeyDomain::new(Direction::PhoneToDesktop, Transport::Tcp, 1),
    )
    .unwrap()
}

fn ping() -> Frame {
    Frame::Ping(PingPayload {
        ping_id: 3,
        sent_time_us: 4,
    })
}

#[test]
fn tcp_prefix_is_aead_authenticated_and_invalid_prefix_does_not_consume_replay() {
    let mut sender = tcp_key();
    let receiver = tcp_key();
    let mut replay = ReplayWindow::new();
    let packet = sender.seal_tcp_frame(&ping()).unwrap();
    assert_eq!(
        u16::from_be_bytes([packet[0], packet[1]]) as usize,
        packet.len() - 2
    );
    let mut changed = packet.clone();
    changed.push(0);
    let body_len = (changed.len() - 2) as u16;
    changed[..2].copy_from_slice(&body_len.to_be_bytes());
    assert_eq!(
        receiver.open_tcp_frame(&changed, &mut replay),
        Err(ProtocolError::AuthenticationFailed)
    );
    assert_eq!(
        receiver.open_tcp_frame(&packet, &mut replay).unwrap().frame,
        ping()
    );
    assert_eq!(
        receiver.open_tcp_frame(&packet, &mut replay),
        Err(ProtocolError::ReplayedSequence { seq: 0 })
    );
}

#[test]
fn adding_a_prefix_to_an_unframed_envelope_cannot_authenticate() {
    let mut sender = tcp_key();
    let receiver = tcp_key();
    let raw = sender.seal_frame(&ping()).unwrap();
    let mut prefixed = (raw.len() as u16).to_be_bytes().to_vec();
    prefixed.extend_from_slice(&raw);
    assert_eq!(
        receiver.open_tcp_frame(&prefixed, &mut ReplayWindow::new()),
        Err(ProtocolError::AuthenticationFailed)
    );
    let valid = sender.seal_tcp_frame(&ping()).unwrap();
    assert_eq!(
        receiver.open_frame(&valid[2..], &mut ReplayWindow::new()),
        Err(ProtocolError::AuthenticationFailed)
    );
}

#[test]
fn tcp_helpers_refuse_udp_key_domains_and_bad_framing() {
    let mut key = TrafficKey::derive(
        &SessionSecret::from_bytes([1; 32]),
        SessionId::from_bytes([2; 16]),
        KeyDomain::new(Direction::PhoneToDesktop, Transport::Udp, 1),
    )
    .unwrap();
    assert!(key.seal_tcp_frame(&ping()).is_err());
    assert_eq!(key.next_sequence(), 0);
    assert!(key.open_tcp_frame(&[], &mut ReplayWindow::new()).is_err());
    let mut sender = tcp_key();
    let receiver = tcp_key();
    let packet = sender.seal_tcp_frame(&ping()).unwrap();
    for cut in 0..packet.len() {
        assert!(
            receiver
                .open_tcp_frame(&packet[..cut], &mut ReplayWindow::new())
                .is_err()
        );
    }
    let mut extra = packet.clone();
    extra.push(0);
    assert!(
        receiver
            .open_tcp_frame(&extra, &mut ReplayWindow::new())
            .is_err()
    );
    assert_eq!(
        receiver
            .open_tcp_frame(&packet, &mut ReplayWindow::new())
            .unwrap()
            .frame,
        ping()
    );
}

#[test]
fn receipt_and_deny_never_issue_a_token() {
    let mut host = PhonePairingHost::new(0);
    let desktop = DesktopHandshake::new("Unverified desktop").unwrap();
    let id = host.begin_connection(source(1), 0).unwrap();
    assert_eq!(host.allow(id, 0), Err(HostError::InvalidState));
    assert_eq!(host.state(), HostState::ReadingRequest);
    assert!(matches!(
        host.receive(id, &desktop.request(), 1).unwrap(),
        HostEvent::ConsentRequested
    ));
    assert_eq!(
        host.consent_request(id).unwrap().desktop_label,
        "Unverified desktop"
    );
    assert_eq!(host.display_code(id, 1), Err(HostError::InvalidState));
    assert_eq!(host.attempts_remaining(id), None);
    assert!(matches!(
        host.deny(id, 2).unwrap(),
        PairingMessage::Abort { .. }
    ));
    assert_eq!(host.state(), HostState::Idle);
    assert_eq!(host.allow(id, 3), Err(HostError::StaleConnection));
}

#[test]
fn one_pending_request_and_stale_callbacks_cannot_replace_new_consent() {
    let mut host = PhonePairingHost::new(0);
    let desktop = DesktopHandshake::new("Desktop").unwrap();
    let first = awaiting_consent(&mut host, &desktop, 0);
    assert_eq!(host.begin_connection(source(2), 1), Err(HostError::Busy));
    assert_eq!(
        host.consent_request(first).unwrap().desktop_label,
        "Desktop"
    );
    host.close_connection(first);
    let second = awaiting_consent(&mut host, &desktop, 2);
    assert_ne!(first, second);
    assert!(!host.close_connection(first));
    assert_eq!(host.allow(first, 3), Err(HostError::StaleConnection));
    assert_eq!(
        host.receive(first, &desktop.request(), 3).unwrap_err(),
        HostError::StaleConnection
    );
    assert_eq!(host.state(), HostState::AwaitingConsent);
    host.allow(second, 4).unwrap();
    assert_eq!(host.allow(second, 4), Err(HostError::InvalidState));
    assert_eq!(host.state(), HostState::AwaitingCode);
}

#[test]
fn five_request_limit_survives_source_churn_busy_and_listener_cancellation() {
    let mut host = PhonePairingHost::new(0);
    let first = host.begin_connection(source(1), 0).unwrap();
    for octet in 2..=5 {
        assert_eq!(
            host.begin_connection(source(octet), 1),
            Err(HostError::Busy)
        );
    }
    host.close_connection(first);
    assert_eq!(
        host.begin_connection(source(6), 2),
        Err(HostError::RateLimited {
            retry_after_ms: 59_998
        })
    );
    assert_eq!(
        host.begin_connection(source(7), 59_999),
        Err(HostError::RateLimited { retry_after_ms: 1 })
    );
    let next = host.begin_connection(source(7), 60_000).unwrap();
    assert_eq!(
        host.begin_connection(source(8), 60_000),
        Err(HostError::RateLimited { retry_after_ms: 1 })
    );
    host.close_connection(next);
    assert!(host.begin_connection(source(8), 60_001).is_ok());
}

#[test]
fn per_source_budget_ignores_new_socket_ids_and_ipv4_mapping() {
    let mut host = PhonePairingHost::new(0);
    for now in 0..5 {
        let address = if now % 2 == 0 {
            source(1)
        } else {
            "::ffff:192.0.2.1".parse().unwrap()
        };
        let id = host.begin_connection(address, now).unwrap();
        assert!(host.close_connection(id));
    }
    assert!(matches!(
        host.begin_connection(source(1), 5),
        Err(HostError::RateLimited { .. })
    ));
    assert!(matches!(
        host.begin_connection(source(2), 5),
        Err(HostError::RateLimited { .. })
    ));
}

#[test]
fn denied_and_malformed_requests_do_not_refund_admission() {
    let mut host = PhonePairingHost::new(0);
    let desktop = DesktopHandshake::new("Desktop").unwrap();
    for now in 0..5 {
        let id = host.begin_connection(source(1), now).unwrap();
        if now % 2 == 0 {
            host.receive(id, &desktop.request(), now).unwrap();
            host.deny(id, now).unwrap();
        } else {
            let invalid = PairingMessage::Abort {
                request_id: [0; 16],
                reason: 1,
            };
            assert!(host.receive(id, &invalid, now).is_err());
        }
        assert_eq!(host.state(), HostState::Idle);
    }
    assert!(matches!(
        host.begin_connection(source(2), 5),
        Err(HostError::RateLimited { .. })
    ));
}

#[test]
fn first_request_consent_and_token_deadlines_expire_without_packets() {
    let mut host = PhonePairingHost::new(0);
    let id = host.begin_connection(source(1), 0).unwrap();
    assert_eq!(host.poll_deadline(2999).unwrap(), None);
    // The old socket must be returned for closure, never silently replaced.
    assert_eq!(host.begin_connection(source(2), 3000), Err(HostError::Busy));
    assert_eq!(host.poll_deadline(3000).unwrap(), Some(id));
    let desktop = DesktopHandshake::new("Desktop").unwrap();
    let id = awaiting_consent(&mut host, &desktop, 3000);
    assert_eq!(host.poll_deadline(32_999).unwrap(), None);
    assert_eq!(host.allow(id, 33_000), Err(HostError::DeadlineExpired));
    assert_eq!(host.state(), HostState::Idle);
    let id = awaiting_consent(&mut host, &desktop, 33_000);
    host.allow(id, 33_010).unwrap();
    assert_eq!(host.deadline_ms(), Some(93_010));
    assert!(host.display_code(id, 93_009).is_ok());
    assert_eq!(
        host.display_code(id, 93_010),
        Err(HostError::DeadlineExpired)
    );
    assert_eq!(host.state(), HostState::Idle);
}

#[test]
fn stalled_pake_confirmation_cancels_token_and_cannot_replenish_attempts() {
    let (mut host, id, mut desktop, code) = consented();
    let a = desktop.start_attempt(&code, 1).unwrap();
    host.receive(id, &a, 1).unwrap();
    assert_eq!(host.attempts_remaining(id), Some(2));
    assert_eq!(host.deadline_ms(), Some(3001));
    assert_eq!(host.poll_deadline(3000).unwrap(), None);
    assert_eq!(host.poll_deadline(3001).unwrap(), Some(id));
    assert!(host.display_code(id, 3001).is_err());
    let other = host.begin_connection(source(1), 3001).unwrap();
    assert!(host.display_code(other, 3001).is_err());
    assert_eq!(host.state(), HostState::ReadingRequest);
}

#[test]
fn wrong_code_retry_retains_token_expiry_and_final_attempt_can_succeed() {
    let (mut host, id, mut desktop, code) = consented();
    let wrong = if code.as_str() == "AAAAAA" {
        "BBBBBB"
    } else {
        "AAAAAA"
    };
    let mut previous = None;
    for now in [1, 1000] {
        let a = desktop.start_attempt(wrong, now).unwrap();
        if let Some(before) = previous {
            assert_ne!(before, a);
        }
        let HostEvent::Reply(b) = host.receive(id, &a, now).unwrap() else {
            panic!("PakeB")
        };
        assert_eq!(
            desktop.handle_pake_b(&b, now).unwrap_err(),
            ProtocolError::PakeFailed
        );
        previous = Some(a);
    }
    assert_eq!(host.attempts_remaining(id), Some(1));
    assert_eq!(host.display_code(id, 1000).unwrap(), code.as_str());
    let a = desktop.start_attempt(&code, 2000).unwrap();
    let HostEvent::Reply(b) = host.receive(id, &a, 2000).unwrap() else {
        panic!("PakeB")
    };
    assert_eq!(host.attempts_remaining(id), Some(0));
    let ca = desktop.handle_pake_b(&b, 2001).unwrap();
    let HostEvent::Ready(ready) = host.receive(id, &ca, 2002).unwrap() else {
        panic!("ready")
    };
    assert!(host.display_code(id, 2002).is_err());
    host.ready_written(id, 2003).unwrap();
    desktop.finish(&ready, 2004).unwrap();
    assert_eq!(host.state(), HostState::Paired);
}

#[test]
fn retry_near_token_expiry_does_not_extend_original_deadline() {
    let (mut host, id, mut desktop, code) = consented();
    let a = desktop.start_attempt(&code, 59_999).unwrap();
    host.receive(id, &a, 59_999).unwrap();
    assert_eq!(host.deadline_ms(), Some(60_000));
    assert_eq!(host.poll_deadline(60_000).unwrap(), Some(id));
    assert!(host.session_mut(id).is_none());
}

#[test]
fn early_pake_request_mismatch_and_invalid_points_cancel_without_session() {
    for case in 0..3 {
        let mut host = PhonePairingHost::new(0);
        let mut desktop = DesktopHandshake::new("Desktop").unwrap();
        let id = awaiting_consent(&mut host, &desktop, 0);
        let mut request_id = *desktop.request().request_id();
        if case != 0 {
            desktop.accept(&host.allow(id, 0).unwrap(), 0).unwrap();
        }
        if case == 1 {
            request_id[0] ^= 1;
        }
        let a = PairingMessage::PakeA {
            request_id,
            point: [0; 65],
        };
        assert!(host.receive(id, &a, 1).is_err());
        assert_eq!(host.state(), HostState::Idle);
        assert!(host.session_mut(id).is_none());
        assert!(host.display_code(id, 1).is_err());
    }
}

#[test]
fn failed_confirmation_and_peer_abort_erase_pending_secrets() {
    let (mut host, id, mut desktop, code) = consented();
    let a = desktop.start_attempt(&code, 1).unwrap();
    let HostEvent::Reply(b) = host.receive(id, &a, 1).unwrap() else {
        panic!("PakeB")
    };
    let mut ca = desktop.handle_pake_b(&b, 1).unwrap();
    let PairingMessage::ConfirmA {
        ref mut confirmation,
        ..
    } = ca
    else {
        panic!("cA")
    };
    confirmation[0] ^= 1;
    assert_eq!(
        host.receive(id, &ca, 2).unwrap_err(),
        HostError::Protocol(ProtocolError::PakeFailed)
    );
    assert_eq!(host.state(), HostState::Idle);
    assert!(host.session_mut(id).is_none());

    let (mut host, id, desktop, _) = consented();
    let abort = PairingMessage::Abort {
        request_id: *desktop.request().request_id(),
        reason: 1,
    };
    assert!(matches!(
        host.receive(id, &abort, 1).unwrap(),
        HostEvent::Cancelled
    ));
    assert!(host.display_code(id, 1).is_err());
    assert_eq!(host.state(), HostState::Idle);
}

#[test]
fn ready_must_be_written_before_session_access_and_only_one_session_exists() {
    let (mut host, id, mut desktop, ready) = ready_pending();
    assert_eq!(host.state(), HostState::SendingReady);
    assert!(host.session_mut(id).is_none());
    assert_eq!(host.begin_connection(source(2), 5), Err(HostError::Busy));
    host.ready_written(id, 5).unwrap();
    let mut session = desktop.finish(&ready, 5).unwrap();
    assert_eq!(
        host.session_mut(id).unwrap().session_id(),
        session.session_id()
    );
    let packet = session.seal(Transport::Tcp, &ping()).unwrap();
    assert_eq!(
        host.session_mut(id)
            .unwrap()
            .open(Transport::Tcp, &packet)
            .unwrap()
            .frame,
        ping()
    );
    assert_eq!(host.begin_connection(source(2), 6), Err(HostError::Busy));
    assert!(host.close_connection(id));
    assert!(host.session_mut(id).is_none());
    assert_eq!(host.state(), HostState::Idle);
}

#[test]
fn stalled_ready_write_discards_pending_session() {
    let (mut host, id, _, ready) = ready_pending();
    let mut writer = FrameWriter::new(4);
    writer
        .queue(
            FrameMode::Authenticated,
            &ready,
            4,
            host.deadline_ms().unwrap(),
        )
        .unwrap();
    writer
        .poll_write(&mut Fault(io::ErrorKind::WouldBlock, 0), 5)
        .unwrap();
    assert_eq!(
        writer.check_deadline(3004),
        Err(TransportError::DeadlineExpired)
    );
    assert_eq!(host.poll_deadline(3004).unwrap(), Some(id));
    assert!(host.session_mut(id).is_none());
    assert_eq!(
        host.ready_written(id, 3004),
        Err(HostError::StaleConnection)
    );
}

#[test]
fn host_clock_regression_erases_secrets_and_does_not_reset_rate_history() {
    let (mut host, id, _, _) = consented();
    host.poll_deadline(100).unwrap();
    assert_eq!(host.poll_deadline(99), Err(HostError::ClockRegression));
    assert!(host.display_code(id, 100).is_err());
    for _ in 0..4 {
        let id = host.begin_connection(source(2), 100).unwrap();
        host.close_connection(id);
    }
    assert!(matches!(
        host.begin_connection(source(3), 100),
        Err(HostError::RateLimited { .. })
    ));
    let mut host = PhonePairingHost::new(u64::MAX - 1);
    assert_eq!(
        host.begin_connection(source(1), u64::MAX - 1),
        Err(HostError::TimeOverflow)
    );
    assert_eq!(host.state(), HostState::Idle);
}

#[test]
fn host_debug_output_redacts_code_label_and_ready_frame() {
    let (host, _, _, code) = consented();
    let debug = format!("{host:?}");
    assert!(!debug.contains(code.as_str()));
    assert!(!debug.contains("Unverified desktop"));
    assert_eq!(
        format!("{:?}", HostEvent::Ready(vec![1, 2, 3])),
        "Ready([frame redacted])"
    );
}

fn socket_pair() -> (TcpStream, TcpStream) {
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    let desktop = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
    let (phone, _) = listener.accept().unwrap();
    for socket in [&desktop, &phone] {
        socket.set_nonblocking(true).unwrap();
        socket.set_nodelay(true).unwrap();
    }
    (desktop, phone)
}

fn socket_transfer(
    sender: &mut TcpStream,
    receiver: &mut TcpStream,
    mode: FrameMode,
    bytes: &[u8],
) -> Vec<u8> {
    let clock = Instant::now();
    let mut writer = FrameWriter::new(0);
    let mut reader = FrameReader::new(mode, 0, 3000).unwrap();
    writer.queue(mode, bytes, 0, 3000).unwrap();
    let mut write_socket = Chunked {
        inner: sender,
        chunk: 3,
        calls: 0,
    };
    let mut read_socket = Chunked {
        inner: receiver,
        chunk: 1,
        calls: 0,
    };
    loop {
        let now = clock.elapsed().as_millis() as u64;
        writer.poll_write(&mut write_socket, now).unwrap();
        if reader.poll_read(&mut read_socket, now).unwrap() == ReadStatus::Complete {
            assert!(!writer.is_pending());
            return reader.frame().unwrap().to_vec();
        }
        std::thread::yield_now();
    }
}

#[test]
fn full_pairing_and_wrong_code_retry_over_fragmented_loopback_tcp() {
    let (mut desktop_socket, mut phone_socket) = socket_pair();
    let mut host = PhonePairingHost::new(0);
    let id = host
        .begin_connection(phone_socket.peer_addr().unwrap().ip(), 0)
        .unwrap();
    let mut desktop = DesktopHandshake::new("Loopback desktop").unwrap();
    let request = socket_transfer(
        &mut desktop_socket,
        &mut phone_socket,
        FrameMode::Handshake,
        &desktop.request().encode().unwrap(),
    );
    assert!(matches!(
        host.receive(id, &PairingMessage::decode(&request).unwrap(), 0)
            .unwrap(),
        HostEvent::ConsentRequested
    ));
    assert!(host.display_code(id, 0).is_err());
    // Test-only explicit consent. Production needs the real Android Allow action.
    let accept = host.allow(id, 0).unwrap();
    let accept = socket_transfer(
        &mut phone_socket,
        &mut desktop_socket,
        FrameMode::Handshake,
        &accept.encode().unwrap(),
    );
    desktop
        .accept(&PairingMessage::decode(&accept).unwrap(), 0)
        .unwrap();
    let code = Zeroizing::new(host.display_code(id, 0).unwrap().to_owned());
    let wrong = if code.as_str() == "AAAAAA" {
        "BBBBBB"
    } else {
        "AAAAAA"
    };
    for (attempt, candidate) in [wrong, code.as_str()].into_iter().enumerate() {
        let now = 1 + attempt as u64;
        let a = desktop
            .start_attempt(candidate, now)
            .unwrap()
            .encode()
            .unwrap();
        let a = socket_transfer(
            &mut desktop_socket,
            &mut phone_socket,
            FrameMode::Handshake,
            &a,
        );
        let HostEvent::Reply(b) = host
            .receive(id, &PairingMessage::decode(&a).unwrap(), now)
            .unwrap()
        else {
            panic!("PakeB")
        };
        let b = socket_transfer(
            &mut phone_socket,
            &mut desktop_socket,
            FrameMode::Handshake,
            &b.encode().unwrap(),
        );
        let confirmation = desktop.handle_pake_b(&PairingMessage::decode(&b).unwrap(), now);
        if attempt == 0 {
            assert_eq!(confirmation.unwrap_err(), ProtocolError::PakeFailed);
            assert_eq!(host.attempts_remaining(id), Some(2));
        } else {
            let ca = socket_transfer(
                &mut desktop_socket,
                &mut phone_socket,
                FrameMode::Handshake,
                &confirmation.unwrap().encode().unwrap(),
            );
            let HostEvent::Ready(ready) = host
                .receive(id, &PairingMessage::decode(&ca).unwrap(), now)
                .unwrap()
            else {
                panic!("ready")
            };
            assert!(host.session_mut(id).is_none());
            let ready = socket_transfer(
                &mut phone_socket,
                &mut desktop_socket,
                FrameMode::Authenticated,
                &ready,
            );
            host.ready_written(id, now).unwrap();
            let mut session = desktop.finish(&ready, now).unwrap();
            let packet = session.seal(Transport::Tcp, &ping()).unwrap();
            let packet = socket_transfer(
                &mut desktop_socket,
                &mut phone_socket,
                FrameMode::Authenticated,
                &packet,
            );
            assert_eq!(
                host.session_mut(id)
                    .unwrap()
                    .open(Transport::Tcp, &packet)
                    .unwrap()
                    .frame,
                ping()
            );
        }
    }
    assert_eq!(host.state(), HostState::Paired);
    assert!(host.close_connection(id));
}

#[test]
fn loopback_disconnect_mid_frame_cancels_connection_without_refunding_budget() {
    let (mut desktop, mut phone) = socket_pair();
    let mut host = PhonePairingHost::new(0);
    let source = phone.peer_addr().unwrap().ip();
    let id = host.begin_connection(source, 0).unwrap();
    let bytes = request_bytes();
    desktop.write_all(&bytes[..4]).unwrap();
    desktop.shutdown(Shutdown::Write).unwrap();
    let mut reader = FrameReader::new(FrameMode::Handshake, 0, 3000).unwrap();
    let clock = Instant::now();
    loop {
        match reader.poll_read(&mut phone, clock.elapsed().as_millis() as u64) {
            Ok(ReadStatus::Pending) => std::thread::yield_now(),
            Err(TransportError::PeerClosed) => break,
            other => panic!("unexpected {other:?}"),
        }
    }
    assert!(host.close_connection(id));
    for _ in 0..4 {
        let id = host.begin_connection(source, 1).unwrap();
        host.close_connection(id);
    }
    assert!(matches!(
        host.begin_connection(source, 2),
        Err(HostError::RateLimited { .. })
    ));
}
