use padlink_protocol::clock::ClockBounds;
use padlink_protocol::edge::EdgeReceiver;
use padlink_protocol::frame::{Buttons, Edge};
use padlink_protocol::input::InputAssembler;
use padlink_protocol::watchdog::{Watchdog, WatchdogPhase};

#[test]
fn uncertainty_must_not_make_an_old_sample_fresh() {
    let bounds = ClockBounds::new(0, 500_000).unwrap();
    assert!(!bounds.is_fresh(1_000_000, 600_000, 250_000).unwrap());
}

#[test]
fn documented_peer_minus_local_offset_converts_to_local_time() {
    let bounds = ClockBounds::new(1_000_000, 0).unwrap();
    assert_eq!(
        bounds.conservative_sample_time(1_000_000, 2_000_000),
        Ok(1_000_000)
    );
}

#[test]
fn rearm_cannot_postpone_expiry_without_new_state_input() {
    let mut watchdog = Watchdog::new(250).unwrap();
    watchdog.activate(0);
    watchdog.on_fresh_input(0, 0).unwrap();
    watchdog.tick(5_000_000);
    watchdog.rearm(29_000_000).unwrap();
    assert_eq!(watchdog.tick(30_000_000).phase, WatchdogPhase::Expired);
}

#[test]
fn rearm_checks_expiry_even_if_timer_tick_has_not_run() {
    let mut watchdog = Watchdog::new(250).unwrap();
    watchdog.activate(0);
    watchdog.tick(5_000_000);
    assert!(watchdog.rearm(30_000_000).is_err());
}

#[test]
fn confirmed_rearm_can_receive_fresh_state_while_reconnecting() {
    let mut watchdog = Watchdog::new(250).unwrap();
    watchdog.activate(0);
    watchdog.on_fresh_input(0, 0).unwrap();
    assert_eq!(watchdog.tick(5_000_000).phase, WatchdogPhase::Reconnecting);
    watchdog.rearm(6_000_000).unwrap();
    assert!(!watchdog.output_allowed());
    assert!(watchdog.on_fresh_input(6_010_000, 6_020_000).unwrap());
    assert_eq!(watchdog.reference_us(), 6_010_000);
}

#[test]
fn old_sample_after_rearm_cannot_extend_session_expiry() {
    let mut watchdog = Watchdog::new(250).unwrap();
    watchdog.activate(0);
    watchdog.on_fresh_input(0, 0).unwrap();
    watchdog.neutralize_now();
    watchdog.rearm(1_000_000).unwrap();
    assert!(!watchdog.on_fresh_input(800_000, 1_100_000).unwrap());
    assert_eq!(watchdog.reference_us(), 0);
    assert_eq!(watchdog.tick(30_000_000).phase, WatchdogPhase::Expired);
}

#[test]
fn packet_after_hold_deadline_requires_epoch_rearm_even_before_tick() {
    let mut watchdog = Watchdog::new(250).unwrap();
    watchdog.activate(0);
    watchdog.on_fresh_input(100_000, 100_000).unwrap();
    assert!(watchdog.on_fresh_input(400_000, 400_000).is_err());
}

#[test]
fn rejected_batch_does_not_leave_edges_in_reorder_buffer() {
    let mut receiver = EdgeReceiver::new();
    let entries = [
        Edge {
            edge_id: 1,
            buttons: Buttons::A,
            event_time_us: 1,
        },
        Edge {
            edge_id: 33,
            buttons: Buttons::neutral(),
            event_time_us: 2,
        },
    ];
    assert!(receiver.receive(&entries).is_err());
    assert_eq!(receiver.buffered(), 0);
}

#[test]
fn recovered_tap_produces_each_backend_state() {
    let mut receiver = EdgeReceiver::new();
    let entries = [
        Edge {
            edge_id: 1,
            buttons: Buttons::A,
            event_time_us: 1,
        },
        Edge {
            edge_id: 2,
            buttons: Buttons::neutral(),
            event_time_us: 2,
        },
    ];
    let delivery = receiver.receive(&entries).unwrap();
    let mut assembler = InputAssembler::new();
    let reports = assembler.apply_edges(&delivery).unwrap();
    let backend_reports = reports
        .iter()
        .map(|report| report.buttons)
        .collect::<Vec<_>>();
    assert_eq!(backend_reports, vec![Buttons::A, Buttons::neutral()]);
}

#[test]
fn invalid_authenticated_payload_does_not_advance_replay_window() {
    use chacha20poly1305::aead::{Aead, KeyInit, Payload};
    use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
    use padlink_protocol::crypto::{
        Direction, KeyDomain, ReplayWindow, SessionId, SessionSecret, TrafficKey, Transport,
    };
    use padlink_protocol::frame::{FrameType, Header};

    let root = SessionSecret::from_bytes(std::array::from_fn(|index| index as u8));
    let session = SessionId::from_bytes(std::array::from_fn(|index| 0xa0 + index as u8));
    let receiver = TrafficKey::derive(
        &root,
        session,
        KeyDomain::new(Direction::PhoneToDesktop, Transport::Udp, 1),
    )
    .unwrap();
    let key = [
        0xa7, 0xb6, 0x80, 0xea, 0x88, 0x92, 0xea, 0xe8, 0xff, 0xe7, 0x4e, 0xeb, 0xbc, 0x15, 0xa8,
        0xca, 0xf6, 0x4a, 0xb9, 0xb6, 0xf2, 0x14, 0x0e, 0xdb, 0xa6, 0xfe, 0x36, 0xa0, 0xd1, 0x41,
        0xbb, 0x89,
    ];
    let header = Header {
        frame_type: FrameType::State,
        session_tag: session.tag(),
        seq: 100,
    }
    .encode();
    let mut nonce = [0_u8; 12];
    nonce[..4].copy_from_slice(&[0x72, 0xdf, 0x32, 0xe2]);
    nonce[4..].copy_from_slice(&100_u64.to_le_bytes());
    let mut payload = [0_u8; 28];
    payload[17] = 0x80;
    let cipher = ChaCha20Poly1305::new(Key::from_slice(&key));
    let ciphertext = cipher
        .encrypt(
            Nonce::from_slice(&nonce),
            Payload {
                msg: &payload,
                aad: &header,
            },
        )
        .unwrap();
    let mut bytes = header.to_vec();
    bytes.extend(ciphertext);
    let mut replay = ReplayWindow::new();
    let error = receiver.open_frame(&bytes, &mut replay).unwrap_err();
    assert_eq!(
        error,
        padlink_protocol::ProtocolError::ReservedNonZero {
            field: "buttons.bit15"
        }
    );
    assert!(replay.accept(0));
}
