//! RFC 9382 Appendix B, P-256/SHA-256/HKDF-SHA256/HMAC-SHA256.
//! Deterministic scalars are available only through the dev test-utils feature.

use pakery_core::crypto::CpaceGroup;
use pakery_crypto::{P256Group, Spake2P256};
use pakery_spake2::{PartyA, PartyB};

fn scalar(value: &str) -> <P256Group as CpaceGroup>::Scalar {
    let mut wide = [0_u8; 64];
    wide[32..].copy_from_slice(&hex::decode(value).unwrap());
    P256Group::scalar_from_wide_bytes(&wide).unwrap()
}

#[test]
fn appendix_b_points_key_and_both_confirmations_match_exactly() {
    let w = scalar("2ee57912099d31560b3a44b1184b9b4866e904c49d12ac5042c97dca461b1a5f");
    let x = scalar("43dd0fd7215bdcb482879fca3220c6a968e66d70b1356cac18bb26c84a78d729");
    let y = scalar("dcb60106f276b02606d8ef0a328c02e4b629f84f89786af5befb0bc75b6e66be");
    let (pa, a) =
        PartyA::<Spake2P256>::start_with_scalar(&w, &x, b"server", b"client", b"").unwrap();
    let (pb, b) =
        PartyB::<Spake2P256>::start_with_scalar(&w, &y, b"server", b"client", b"").unwrap();
    assert_eq!(
        hex::encode(&pa),
        "04a56fa807caaa53a4d28dbb9853b9815c61a411118a6fe516a8798434751470f9010153ac33d0d5f2047ffdb1a3e42c9b4e6be662766e1eeb4116988ede5f912c"
    );
    assert_eq!(
        hex::encode(&pb),
        "0406557e482bd03097ad0cbaa5df82115460d951e3451962f1eaf4367a420676d09857ccbc522686c83d1852abfa8ed6e4a1155cf8f1543ceca528afb591a1e0b7"
    );
    let a = a.finish(&pb).unwrap();
    let b = b.finish(&pa).unwrap();
    assert_eq!(
        hex::encode(a.session_key.as_bytes()),
        "0e0672dc86f8e45565d338b0540abe69"
    );
    assert_eq!(a.session_key.as_bytes(), b.session_key.as_bytes());
    assert_eq!(
        hex::encode(&a.confirmation_mac),
        "58ad4aa88e0b60d5061eb6b5dd93e80d9c4f00d127c65b3b35b1b5281fee38f0"
    );
    assert_eq!(
        hex::encode(&b.confirmation_mac),
        "d3e2e547f1ae04f2dbdbf0fc4b79f8ecff2dff314b5d32fe9fcef2fb26dc459b"
    );
    a.verify_peer_confirmation(&b.confirmation_mac).unwrap();
    b.verify_peer_confirmation(&a.confirmation_mac).unwrap();
    assert!(a.verify_peer_confirmation(&a.confirmation_mac).is_err());
    assert!(
        b.verify_peer_confirmation(&b.confirmation_mac[..31])
            .is_err()
    );
}
