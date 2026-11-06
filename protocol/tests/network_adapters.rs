use padlink_protocol::frame::{Frame, PingPayload};
use padlink_protocol::pairing::{
    host::HostState,
    net::{DesktopEvent, DesktopPairingClient, PhoneEvent, PhonePairingServer},
};
use zeroize::Zeroizing;
#[test]
fn production_adapters_pair_retry_after_human_delay_and_exchange_encrypted_ping() {
    let mut phone = PhonePairingServer::new(0);
    let endpoint = phone.start("127.0.0.1:0".parse().unwrap()).unwrap();
    let mut desktop = DesktopPairingClient::connect(endpoint, "Adapter test", 0).unwrap();
    let mut code = Zeroizing::new(String::new());
    let clock = std::time::Instant::now();
    let mut offset = 0;
    let mut submitted = 0;
    let mut finished = false;
    let mut pinged = false;
    let mut waiting_retry = false;
    for _ in 0..100_000 {
        let mut now = clock.elapsed().as_millis() as u64 + offset;
        match phone.poll(now).unwrap() {
            PhoneEvent::Consent { id, .. } => {
                assert_eq!(phone.state(), HostState::AwaitingConsent);
                phone.allow(id, now).unwrap();
                *code = phone.code(id, now).unwrap().to_owned();
            }
            PhoneEvent::Pending
            | PhoneEvent::Paired { .. }
            | PhoneEvent::Closed { .. }
            | PhoneEvent::Frame(_) => {}
        }
        match desktop.poll(now).unwrap() {
            DesktopEvent::EnterCode => {
                if submitted == 0 {
                    desktop
                        .enter_code(
                            if code.as_str() == "AAAAAA" {
                                "BBBBBB"
                            } else {
                                "AAAAAA"
                            },
                            now,
                        )
                        .unwrap();
                    submitted = 1;
                } else {
                    waiting_retry = true;
                }
            }
            DesktopEvent::WrongCode => {}
            DesktopEvent::Paired => {
                desktop
                    .send(
                        &Frame::Ping(PingPayload {
                            ping_id: 7,
                            sent_time_us: now * 1000,
                        }),
                        now,
                    )
                    .unwrap();
                pinged = true;
            }
            DesktopEvent::Frame(Frame::Pong(pong)) => {
                assert_eq!(pong.ping_id, 7);
                finished = true;
                break;
            }
            DesktopEvent::Frame(_) => panic!("unexpected frame"),
            DesktopEvent::Pending => {}
        }
        if waiting_retry && phone.state() == HostState::AwaitingCode {
            offset += 15_000;
            now += 15_000;
            desktop.enter_code(&code, now).unwrap();
            submitted = 2;
            waiting_retry = false;
        }
        std::thread::yield_now();
    }
    assert!(pinged && finished);
    assert_eq!(submitted, 2);
    assert_eq!(phone.state(), HostState::Paired);
    desktop.close();
    phone.stop();
    assert_eq!(phone.state(), HostState::Idle);
}
#[test]
fn denial_is_reported_and_socket_cancellation_clears_phone_state() {
    let mut phone = PhonePairingServer::new(0);
    let endpoint = phone.start("127.0.0.1:0".parse().unwrap()).unwrap();
    let mut desktop = DesktopPairingClient::connect(endpoint, "Deny test", 0).unwrap();
    let mut denied = false;
    let mut failed = false;
    for now in 0..1000 {
        if let PhoneEvent::Consent { id, .. } = phone.poll(now).unwrap() {
            phone.deny(id, now).unwrap();
            denied = true;
        }
        if desktop.poll(now).is_err() {
            failed = true;
            break;
        }
        std::thread::yield_now();
    }
    assert!(denied && failed);
    assert_eq!(phone.state(), HostState::Idle);
    phone.stop();
}
#[test]
fn listener_restart_keeps_rate_limits_and_stale_user_actions_cannot_allow() {
    let mut phone = PhonePairingServer::new(0);
    for now in 0..5 {
        let endpoint = phone.start("127.0.0.1:0".parse().unwrap()).unwrap();
        let _desktop = std::net::TcpStream::connect(endpoint).unwrap();
        for _ in 0..1000 {
            phone.poll(now).unwrap();
            if phone.state() == HostState::ReadingRequest {
                break;
            }
            std::thread::yield_now();
        }
        assert_eq!(phone.state(), HostState::ReadingRequest);
        phone.stop();
    }
    let endpoint = phone.start("127.0.0.1:0".parse().unwrap()).unwrap();
    let _desktop = std::net::TcpStream::connect(endpoint).unwrap();
    phone.poll(5).unwrap();
    assert_eq!(phone.state(), HostState::Idle);
    assert!(phone.allow(1, 5).is_err());
    phone.stop();
}
