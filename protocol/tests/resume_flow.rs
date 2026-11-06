use padlink_protocol::{
    ProtocolError,
    crypto::Transport,
    frame::{Frame, StatePayload},
    pairing::{
        DesktopHandshake, PairedSession, PairingMessage, PhoneHandshake,
        resume::{ResumePath, SessionLease},
    },
};
use zeroize::Zeroizing;
fn paired() -> (PairedSession, PairedSession) {
    let mut d = DesktopHandshake::new("Resume test").unwrap();
    let PairingMessage::Request(request) = d.request() else {
        panic!("request")
    };
    let mut p = PhoneHandshake::consent(&request, 0).unwrap();
    d.accept(&p.accept(), 0).unwrap();
    let code = Zeroizing::new(p.display_code(0).unwrap().to_owned());
    let a = d.start_attempt(&code, 0).unwrap();
    let b = p.handle_pake_a(&a, 0).unwrap();
    let ca = d.handle_pake_b(&b, 0).unwrap();
    let (p, ready) = p.handle_confirm_a(&ca, 0).unwrap();
    (d.finish(&ready, 0).unwrap(), p)
}
fn path(transport: Transport) -> ResumePath {
    ResumePath {
        transport,
        desktop: "127.0.0.1:41338".parse().unwrap(),
        phone: "127.0.0.1:41337".parse().unwrap(),
    }
}

#[test]
fn resume_confirms_endpoints_new_epoch_and_keys_without_extending_expiry() {
    for transport in [Transport::Udp, Transport::Tcp] {
        let (d, mut p) = paired();
        let old = p
            .seal(transport, &Frame::State(StatePayload::default()))
            .unwrap();
        let path = path(transport);
        let mut d = SessionLease::new(d, 0)
            .unwrap()
            .resume(path, 10_000)
            .unwrap();
        let mut p = SessionLease::new(p, 0)
            .unwrap()
            .resume(path, 10_000)
            .unwrap();
        let a = d.begin(10_000).unwrap();
        assert!(d.begin(10_000).is_err());
        let b = p
            .receive(path.desktop, &a, 10_001)
            .unwrap()
            .frames
            .remove(0);
        let ca = d.receive(path.phone, &b, 10_002).unwrap().frames.remove(0);
        let mut output = p.receive(path.desktop, &ca, 10_003).unwrap();
        assert_eq!(output.frames.len(), 2);
        assert!(
            !d.receive(path.phone, &output.frames.remove(0), 10_004)
                .unwrap()
                .ready_to_commit
        );
        assert!(
            d.receive(path.phone, &output.frames.remove(0), 10_005)
                .unwrap()
                .ready_to_commit
        );
        p.ready_written(10_005).unwrap();
        let (mut d, accepted) = d.finish(10_006).unwrap();
        let (mut p, _) = p.finish(10_006).unwrap();
        assert_eq!(accepted, path);
        assert_eq!(d.expires_ms(), 30_000);
        assert_eq!(p.expires_ms(), 30_000);
        assert_eq!(d.session_mut(10_006).unwrap().epoch(), 2);
        assert!(
            d.session_mut(10_006)
                .unwrap()
                .open(transport, &old)
                .is_err()
        );
        let state = Frame::State(StatePayload::default());
        let packet = p
            .session_mut(10_006)
            .unwrap()
            .seal(transport, &state)
            .unwrap();
        assert_eq!(
            d.session_mut(10_006)
                .unwrap()
                .open(transport, &packet)
                .unwrap()
                .frame,
            state
        );
        assert!(
            d.session_mut(10_006)
                .unwrap()
                .open(transport, &packet)
                .is_err()
        );
        assert_eq!(d.check_live(30_000), Err(ProtocolError::SessionExpired));
    }
}
#[test]
fn candidate_timeout_and_original_expiry_erase_secrets() {
    let (d, p) = paired();
    let mut d = SessionLease::new(d, 0)
        .unwrap()
        .resume(path(Transport::Tcp), 100)
        .unwrap();
    let _p = SessionLease::new(p, 0).unwrap();
    d.begin(100).unwrap();
    assert_eq!(d.check_live(2100), Err(ProtocolError::SessionExpired));
    assert!(d.begin(2101).is_err());
    let (d, _) = paired();
    let mut d = SessionLease::new(d, 0)
        .unwrap()
        .resume(path(Transport::Udp), 29_999)
        .unwrap();
    assert_eq!(d.deadline_ms(), 30_000);
    assert_eq!(d.check_live(30_000), Err(ProtocolError::SessionExpired));
}
#[test]
fn endpoint_and_transport_transcript_changes_cannot_confirm() {
    for change in 0..3 {
        let (d, p) = paired();
        let dpath = path(Transport::Tcp);
        let mut ppath = dpath;
        if change == 0 {
            ppath.phone.set_port(50000)
        }
        if change == 1 {
            ppath.desktop.set_port(50001)
        }
        if change == 2 {
            ppath.transport = Transport::Udp
        }
        let mut d = SessionLease::new(d, 0).unwrap().resume(dpath, 0).unwrap();
        let mut p = SessionLease::new(p, 0).unwrap().resume(ppath, 0).unwrap();
        let a = d.begin(0).unwrap();
        let result = p.receive(ppath.desktop, &a, 1);
        if change == 2 {
            assert!(result.is_err());
            continue;
        }
        let b = result.unwrap().frames.remove(0);
        let ca = d.receive(dpath.phone, &b, 2).unwrap().frames.remove(0);
        assert!(p.receive(ppath.desktop, &ca, 3).is_err());
        assert!(p.finish(4).is_err());
    }
}
#[test]
fn wrong_source_does_not_commit_or_consume_legitimate_challenge() {
    let (d, p) = paired();
    let path = path(Transport::Udp);
    let mut d = SessionLease::new(d, 0).unwrap().resume(path, 0).unwrap();
    let mut p = SessionLease::new(p, 0).unwrap().resume(path, 0).unwrap();
    let a = d.begin(0).unwrap();
    assert!(
        p.receive("127.0.0.2:41338".parse().unwrap(), &a, 1)
            .is_err()
    );
    assert!(p.receive(path.desktop, &a, 2).is_ok());
}
#[test]
fn tampered_resume_and_clock_regression_fail_closed() {
    let (d, p) = paired();
    let path = path(Transport::Tcp);
    let mut d = SessionLease::new(d, 0).unwrap().resume(path, 0).unwrap();
    let mut p = SessionLease::new(p, 0).unwrap().resume(path, 0).unwrap();
    let mut a = d.begin(0).unwrap();
    let last = a.len() - 1;
    a[last] ^= 1;
    assert!(p.receive(path.desktop, &a, 1).is_err());
    assert!(p.finish(2).is_err());
    d.check_live(100).unwrap();
    assert_eq!(d.check_live(99), Err(ProtocolError::ClockRegression));
}
#[test]
fn fresh_input_is_sample_anchored_and_cannot_revive_expired_or_closed_session() {
    let (d, _) = paired();
    let mut lease = SessionLease::new(d, 0).unwrap();
    lease.fresh_input(900, 1000).unwrap();
    assert_eq!(lease.expires_ms(), 30_900);
    assert_eq!(
        lease.fresh_input(800, 1100),
        Err(ProtocolError::StaleSampleTime)
    );
    assert_eq!(
        lease.fresh_input(1101, 1100),
        Err(ProtocolError::FutureSampleTime)
    );
    assert_eq!(
        lease.fresh_input(30_900, 30_900),
        Err(ProtocolError::SessionExpired)
    );
    let (d, _) = paired();
    let mut lease = SessionLease::new(d, 0).unwrap();
    lease.close();
    assert!(lease.fresh_input(1, 1).is_err());
    let (d, _) = paired();
    assert!(SessionLease::new(d, u64::MAX - 1).is_err());
}
