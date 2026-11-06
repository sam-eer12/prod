//! Pairing-core failure tests. No sockets, Android UI, or live input are used.

use padlink_protocol::crypto::Transport;
use padlink_protocol::frame::{Frame, PingPayload, StatePayload};
use padlink_protocol::pairing::wire::{PairingMessage, PairingRequest, preauth_body_len};
use padlink_protocol::pairing::{DesktopHandshake, PhoneHandshake, Role};
use padlink_protocol::{MAX_HANDSHAKE_FRAME_LEN, ProtocolError};
use zeroize::Zeroizing;

fn start() -> (DesktopHandshake, PhoneHandshake) {
    let mut desktop = DesktopHandshake::new("Test desktop").unwrap();
    let PairingMessage::Request(request) = desktop.request() else {
        panic!("expected request")
    };
    let phone = PhoneHandshake::consent(&request, 0).unwrap();
    desktop.accept(&phone.accept(), 0).unwrap();
    (desktop, phone)
}

fn round_trip(message: PairingMessage) -> PairingMessage {
    let bytes = message.encode().unwrap();
    assert_eq!(
        u16::from_be_bytes([bytes[0], bytes[1]]) as usize,
        bytes.len() - 2
    );
    assert!(bytes.len() <= MAX_HANDSHAKE_FRAME_LEN);
    let decoded = PairingMessage::decode(&bytes).unwrap();
    assert_eq!(decoded, message);
    decoded
}

#[test]
fn mutual_confirmation_ready_and_bidirectional_traffic() {
    let (mut desktop, mut phone) = start();
    let code = Zeroizing::new(phone.display_code(1).unwrap().to_owned());
    let a = round_trip(desktop.start_attempt(&code, 1).unwrap());
    let b = round_trip(phone.handle_pake_a(&a, 2).unwrap());
    let ca = round_trip(desktop.handle_pake_b(&b, 3).unwrap());
    let (mut phone_session, ready) = phone.handle_confirm_a(&ca, 4).unwrap();
    assert!(phone.display_code(5).is_err());
    let mut desktop_session = desktop.finish(&ready, 5).unwrap();
    assert_eq!(desktop_session.role(), Role::Desktop);
    assert_eq!(phone_session.role(), Role::Phone);
    assert_eq!(desktop_session.session_id(), phone_session.session_id());
    assert!(matches!(
        desktop_session.open(Transport::Tcp, &ready),
        Err(ProtocolError::ReplayedSequence { seq: 0 })
    ));

    let ping = Frame::Ping(PingPayload {
        ping_id: 1,
        sent_time_us: 5_000,
    });
    let packet = desktop_session.seal(Transport::Tcp, &ping).unwrap();
    assert_eq!(
        phone_session.open(Transport::Tcp, &packet).unwrap().frame,
        ping
    );
    let state = Frame::State(StatePayload::default());
    let packet = phone_session.seal(Transport::Udp, &state).unwrap();
    assert!(desktop_session.open(Transport::Tcp, &packet).is_err());
    assert_eq!(
        desktop_session.open(Transport::Udp, &packet).unwrap().frame,
        state
    );
    assert!(desktop.finish(&ready, 6).is_err());
}

#[test]
fn wrong_code_retry_uses_new_ephemeral_without_new_consent_or_deadline() {
    let (mut desktop, mut phone) = start();
    let code = Zeroizing::new(phone.display_code(1).unwrap().to_owned());
    let wrong = if code.as_str() == "AAAAAA" {
        "BBBBBB"
    } else {
        "AAAAAA"
    };
    let first = desktop.start_attempt(wrong, 1).unwrap();
    let b = phone.handle_pake_a(&first, 2).unwrap();
    assert_eq!(
        desktop.handle_pake_b(&b, 3).unwrap_err(),
        ProtocolError::PakeFailed
    );
    assert_eq!(phone.attempts_remaining(), 2);
    let second = desktop.start_attempt(&code, 4).unwrap();
    assert_ne!(first, second);
    let b = phone.handle_pake_a(&second, 5).unwrap();
    assert_eq!(phone.attempts_remaining(), 1);
    assert_eq!(phone.expires_at_ms(), 60_000);
    let ca = desktop.handle_pake_b(&b, 6).unwrap();
    let (_, ready) = phone.handle_confirm_a(&ca, 7).unwrap();
    desktop.finish(&ready, 8).unwrap();
}

#[test]
fn three_failed_attempts_lock_token_globally() {
    let (mut desktop, mut phone) = start();
    let code = Zeroizing::new(phone.display_code(1).unwrap().to_owned());
    let wrong = if code.as_str() == "AAAAAA" {
        "BBBBBB"
    } else {
        "AAAAAA"
    };
    for remaining in (0..3).rev() {
        let a = desktop.start_attempt(wrong, 10).unwrap();
        let b = phone.handle_pake_a(&a, 11).unwrap();
        assert_eq!(
            desktop.handle_pake_b(&b, 12).unwrap_err(),
            ProtocolError::PakeFailed
        );
        phone.fail_attempt();
        assert_eq!(phone.attempts_remaining(), remaining);
    }
    let a = desktop.start_attempt(&code, 20).unwrap();
    assert_eq!(
        phone.handle_pake_a(&a, 21).unwrap_err(),
        ProtocolError::PairingTokenLocked
    );
    assert!(phone.display_code(22).is_err());
}

#[test]
fn final_reserved_attempt_can_succeed() {
    let (mut desktop, mut phone) = start();
    let code = Zeroizing::new(phone.display_code(1).unwrap().to_owned());
    for _ in 0..2 {
        let a = desktop.start_attempt(&code, 1).unwrap();
        phone.handle_pake_a(&a, 2).unwrap();
        phone.fail_attempt();
        desktop.retry(3).unwrap();
    }
    let a = desktop.start_attempt(&code, 4).unwrap();
    let b = phone.handle_pake_a(&a, 5).unwrap();
    assert_eq!(phone.attempts_remaining(), 0);
    let ca = desktop.handle_pake_b(&b, 6).unwrap();
    let (_, ready) = phone.handle_confirm_a(&ca, 7).unwrap();
    desktop.finish(&ready, 8).unwrap();
}

#[test]
fn accepted_metadata_is_bound_to_key_confirmation() {
    for change in 0..4 {
        let mut desktop = DesktopHandshake::new("Desktop").unwrap();
        let PairingMessage::Request(mut request) = desktop.request() else {
            panic!("request")
        };
        if change == 0 {
            request.desktop_label = "Other desktop".to_owned();
        }
        if change == 1 {
            request.desktop_nonce[0] ^= 1;
        }
        let mut phone = PhoneHandshake::consent(&request, 0).unwrap();
        let mut accept = phone.accept();
        let PairingMessage::Accept(ref mut metadata) = accept else {
            panic!("accept")
        };
        if change == 2 {
            metadata.phone_nonce[0] ^= 1;
        }
        if change == 3 {
            metadata.session_id = padlink_protocol::crypto::SessionId::from_bytes([0; 16]);
        }
        desktop.accept(&accept, 0).unwrap();
        let code = Zeroizing::new(phone.display_code(1).unwrap().to_owned());
        let a = desktop.start_attempt(&code, 1).unwrap();
        let b = phone.handle_pake_a(&a, 2).unwrap();
        assert_eq!(
            desktop.handle_pake_b(&b, 3).unwrap_err(),
            ProtocolError::PakeFailed
        );
    }
}

#[test]
fn failed_desktop_confirmation_never_releases_a_phone_session() {
    let (mut desktop, mut phone) = start();
    let code = Zeroizing::new(phone.display_code(1).unwrap().to_owned());
    let a = desktop.start_attempt(&code, 1).unwrap();
    let b = phone.handle_pake_a(&a, 2).unwrap();
    let mut ca = desktop.handle_pake_b(&b, 3).unwrap();
    let PairingMessage::ConfirmA {
        ref mut confirmation,
        ..
    } = ca
    else {
        panic!("confirmation")
    };
    confirmation[0] ^= 1;
    assert_eq!(
        phone.handle_confirm_a(&ca, 4).unwrap_err(),
        ProtocolError::PakeFailed
    );
    assert_eq!(phone.attempts_remaining(), 2);
    assert!(phone.handle_confirm_a(&ca, 5).is_err());
    desktop.retry(6).unwrap();
}

#[test]
fn expiry_during_confirmation_discards_all_pending_secrets() {
    let (mut desktop, mut phone) = start();
    let code = Zeroizing::new(phone.display_code(1).unwrap().to_owned());
    let a = desktop.start_attempt(&code, 1).unwrap();
    let b = phone.handle_pake_a(&a, 2).unwrap();
    let ca = desktop.handle_pake_b(&b, 3).unwrap();
    assert_eq!(
        phone.handle_confirm_a(&ca, 60_000).unwrap_err(),
        ProtocolError::PairingTokenExpired
    );
    assert!(phone.display_code(60_001).is_err());
    assert_eq!(
        desktop.finish(&[], 60_000).unwrap_err(),
        ProtocolError::PairingTokenExpired
    );
}

#[test]
fn encrypted_ready_must_authenticate_before_desktop_session_release() {
    let (mut desktop, mut phone) = start();
    let code = Zeroizing::new(phone.display_code(1).unwrap().to_owned());
    let a = desktop.start_attempt(&code, 1).unwrap();
    let b = phone.handle_pake_a(&a, 2).unwrap();
    let ca = desktop.handle_pake_b(&b, 3).unwrap();
    let (_, mut ready) = phone.handle_confirm_a(&ca, 4).unwrap();
    let last = ready.len() - 1;
    ready[last] ^= 1;
    assert_eq!(
        desktop.finish(&ready, 5).unwrap_err(),
        ProtocolError::AuthenticationFailed
    );
    assert!(desktop.finish(&ready, 6).is_err());
}

#[test]
fn early_confirmation_and_cancellation_cannot_create_sessions() {
    let (mut desktop, mut phone) = start();
    let request_id = *desktop.request().request_id();
    let ca = PairingMessage::ConfirmA {
        request_id,
        confirmation: [0; 32],
    };
    assert_eq!(
        phone.handle_confirm_a(&ca, 1).unwrap_err(),
        ProtocolError::PairingState
    );
    desktop.cancel();
    phone.cancel();
    assert!(desktop.start_attempt("AAAAAA", 2).is_err());
    assert!(desktop.finish(&[], 2).is_err());
    assert!(phone.display_code(2).is_err());
}

#[test]
fn abort_and_request_mismatch_invalidate_token() {
    for mismatch in [false, true] {
        let (mut desktop, mut phone) = start();
        let mut request_id = *desktop.request().request_id();
        if mismatch {
            request_id[0] ^= 1;
        }
        let abort = round_trip(PairingMessage::Abort {
            request_id,
            reason: 1,
        });
        assert!(phone.handle_pake_a(&abort, 1).is_err());
        assert!(phone.display_code(2).is_err());
        assert!(desktop.accept(&abort, 1).is_err());
        assert!(desktop.start_attempt("AAAAAA", 2).is_err());
    }
}

#[test]
fn all_pre_auth_codecs_enforce_exact_lengths_and_bounds() {
    let desktop = DesktopHandshake::new(&"x".repeat(64)).unwrap();
    let request = round_trip(desktop.request());
    let PairingMessage::Request(ref request_body) = request else {
        panic!("request")
    };
    let phone = PhoneHandshake::consent(request_body, 0).unwrap();
    round_trip(phone.accept());
    let request_id = request_body.request_id;
    for message in [
        request,
        phone.accept(),
        PairingMessage::PakeA {
            request_id,
            point: [4; 65],
        },
        PairingMessage::PakeB {
            request_id,
            point: [4; 65],
            confirmation: [5; 32],
        },
        PairingMessage::ConfirmA {
            request_id,
            confirmation: [6; 32],
        },
        PairingMessage::Abort {
            request_id,
            reason: 2,
        },
    ] {
        let bytes = round_trip(message).encode().unwrap();
        for cut in 0..bytes.len() {
            assert!(PairingMessage::decode(&bytes[..cut]).is_err());
        }
        let mut extra = bytes.clone();
        extra.push(0);
        assert!(PairingMessage::decode(&extra).is_err());
    }
    assert!(preauth_body_len([0, 0]).is_err());
    assert_eq!(preauth_body_len((4094_u16).to_be_bytes()).unwrap(), 4094);
    assert!(preauth_body_len((4095_u16).to_be_bytes()).is_err());
    assert!(PairingMessage::decode(&vec![0; 4097]).is_err());
}

#[test]
fn unsupported_suites_versions_and_unsafe_labels_fail_closed() {
    for label in [
        "",
        " ",
        "Bad\nname",
        "\u{202e}name",
        "\u{1b}[31m",
        &"x".repeat(65),
    ] {
        assert!(DesktopHandshake::new(label).is_err());
    }
    let desktop = DesktopHandshake::new("Desktop").unwrap();
    let PairingMessage::Request(mut request) = desktop.request() else {
        panic!("request")
    };
    request.suite = 2;
    assert!(matches!(
        PhoneHandshake::consent(&request, 0),
        Err(ProtocolError::UnsupportedSuite(2))
    ));
    request.suite = 1;
    request.version = 2;
    assert!(PhoneHandshake::consent(&request, 0).is_err());
    let mut bytes = desktop.request().encode().unwrap();
    bytes[3] = 0x21;
    assert!(PairingMessage::decode(&bytes).is_err());
    bytes[3] = 0x1f;
    assert!(PairingMessage::decode(&bytes).is_err());
}

#[test]
fn malformed_points_are_rejected_without_session_or_panic() {
    let (mut desktop, mut phone) = start();
    let request_id = *desktop.request().request_id();
    let invalid = round_trip(PairingMessage::PakeA {
        request_id,
        point: [0; 65],
    });
    assert_eq!(
        phone.handle_pake_a(&invalid, 1).unwrap_err(),
        ProtocolError::PakeFailed
    );
    assert_eq!(phone.attempts_remaining(), 3);
    let code = Zeroizing::new(phone.display_code(2).unwrap().to_owned());
    let a = desktop.start_attempt(&code, 2).unwrap();
    let mut b = phone.handle_pake_a(&a, 3).unwrap();
    let PairingMessage::PakeB { ref mut point, .. } = b else {
        panic!("response")
    };
    *point = [0; 65];
    assert_eq!(
        desktop.handle_pake_b(&b, 4).unwrap_err(),
        ProtocolError::PakeFailed
    );
}

#[test]
fn debug_output_omits_passwords_and_transcripts() {
    let (desktop, mut phone) = start();
    let code = Zeroizing::new(phone.display_code(1).unwrap().to_owned());
    let output = format!("{desktop:?} {phone:?} {:?}", desktop.request());
    assert!(!output.contains(code.as_str()));
    assert!(!output.contains("Test desktop"));
}

#[test]
fn parser_rejects_arbitrary_bytes_without_panicking() {
    for length in 0..=4200 {
        let bytes: Vec<u8> = (0..length)
            .map(|index| ((index * 71 + length * 17) & 255) as u8)
            .collect();
        let _ = PairingMessage::decode(&bytes);
    }
}

#[test]
fn request_roundtrip_does_not_issue_a_token() {
    let request = PairingRequest {
        version: 1,
        suite: 1,
        request_id: [1; 16],
        desktop_nonce: [2; 16],
        desktop_label: "Unverified".to_owned(),
    };
    round_trip(PairingMessage::Request(request));
}
