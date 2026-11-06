//! End-to-end protocol-core flow without sockets or a real backend.
//!
//! This exercises the same public API a daemon will use: record a short tap,
//! encrypt it, authenticate and replay-check it, apply it in order, feed a
//! fresh State sample into the watchdog, then require an explicit rearm.

use padlink_protocol::ProtocolError;
use padlink_protocol::crypto::{
    Direction, KeyDomain, ReplayWindow, SessionId, SessionSecret, TrafficKey, Transport,
};
use padlink_protocol::edge::{EdgeJournal, EdgeReceiver};
use padlink_protocol::frame::{Buttons, Frame, StatePayload, Stick};
use padlink_protocol::input::{InputAssembler, StateDisposition};
use padlink_protocol::watchdog::{Watchdog, WatchdogPhase};

fn ms(value: u64) -> u64 {
    value * 1_000
}

#[test]
fn short_tap_survives_transport_and_drives_the_watchdog() {
    let root = SessionSecret::from_bytes([0x11; 32]);
    let session = SessionId::from_bytes([0x22; 16]);
    let domain = KeyDomain::new(Direction::PhoneToDesktop, Transport::Udp, 1);

    let mut phone = TrafficKey::derive(&root, session, domain).unwrap();
    let desktop = TrafficKey::derive(&root, session, domain).unwrap();
    let mut replay = ReplayWindow::new();

    let mut journal = EdgeJournal::new();
    let mut receiver = EdgeReceiver::new();
    let mut assembler = InputAssembler::new();
    let mut watchdog = Watchdog::new(250).unwrap();
    watchdog.activate(0);

    // Press and release both happen between regular state ticks.
    journal.push(Buttons::A, ms(100)).unwrap();
    journal.push(Buttons::neutral(), ms(110)).unwrap();
    let edges = Frame::Edges(journal.pending_batch(12).unwrap());
    let state = Frame::State(StatePayload {
        latest_edge_id: 2,
        sample_time_us: ms(110),
        buttons: Buttons::neutral(),
        left_trigger: 30,
        right_trigger: 0,
        left_stick: Stick {
            x: 1_000,
            y: -1_000,
        },
        right_stick: Stick::NEUTRAL,
    });

    let edges_packet = phone.seal_frame(&edges).unwrap();
    let state_packet = phone.seal_frame(&state).unwrap();

    // A duplicate edge packet is rejected before it can affect the journal.
    let opened_edges = desktop.open_frame(&edges_packet, &mut replay).unwrap();
    assert_eq!(opened_edges.frame, edges);
    assert_eq!(
        desktop.open_frame(&edges_packet, &mut replay),
        Err(ProtocolError::ReplayedSequence { seq: 0 })
    );

    let Frame::Edges(payload) = opened_edges.frame else {
        panic!("expected edges");
    };
    let delivery = receiver.receive(&payload.entries).unwrap();
    assert_eq!(delivery.applied.len(), 2);
    let reports = assembler.apply_edges(&delivery).unwrap();
    assert_eq!(
        reports
            .iter()
            .map(|report| report.buttons)
            .collect::<Vec<_>>(),
        vec![Buttons::A, Buttons::neutral()]
    );
    assert_eq!(assembler.output().buttons, Buttons::neutral());

    let opened_state = desktop.open_frame(&state_packet, &mut replay).unwrap();
    let Frame::State(payload) = opened_state.frame else {
        panic!("expected state");
    };
    assert_eq!(assembler.apply_state(&payload), StateDisposition::Applied);
    assert_eq!(assembler.output().left_trigger, 30);
    assert_eq!(
        assembler.output().left_stick,
        Stick {
            x: 1_000,
            y: -1_000
        }
    );

    // The sample was taken at 110 ms; the hold deadline is 360 ms.
    assert!(watchdog.on_fresh_input(ms(110), ms(120)).unwrap());
    assert_eq!(watchdog.tick(ms(359)).phase, WatchdogPhase::Active);
    assert_eq!(watchdog.tick(ms(360)).phase, WatchdogPhase::Neutral);
    assert!(!watchdog.output_allowed());

    // A later fresh packet cannot silently rearm a latched-off watchdog.
    assert_eq!(
        watchdog.on_fresh_input(ms(400), ms(400)),
        Err(ProtocolError::WatchdogNotRearmable)
    );

    // Recovery requires an explicit epoch rearm and then fresh neutral input.
    watchdog.rearm(ms(500)).unwrap();
    assert!(watchdog.on_fresh_input(ms(500), ms(500)).unwrap());
    assert!(watchdog.output_allowed());
}
