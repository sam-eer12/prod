//! Adapter around the selected RFC 9382 implementation. No substitute PAKE.

use hkdf::Hkdf;
use pakery_core::crypto::CpaceGroup;
use pakery_crypto::{P256Group, Spake2P256};
use pakery_spake2::{PartyA, PartyAState, PartyB, Spake2Output};
use sha2::{Digest, Sha256, Sha512};
use zeroize::Zeroizing;

use super::random;
use super::wire::{PairingAccept, PairingRequest};
use super::{CONFIRMATION_LEN, PAKE_POINT_LEN};
use crate::code::normalize_pairing_code;
use crate::crypto::SessionSecret;
use crate::error::ProtocolError;

pub(crate) type DesktopPake = PartyAState<Spake2P256>;

pub(crate) struct Context {
    pub request: PairingRequest,
    pub accept: PairingAccept,
}

impl Context {
    fn identities(&self) -> (Vec<u8>, Vec<u8>) {
        let mut desktop = b"padlink/v1/pair-desktop".to_vec();
        desktop.extend_from_slice(&self.request.request_id);
        desktop.extend_from_slice(&self.request.desktop_nonce);
        let mut phone = b"padlink/v1/pair-phone".to_vec();
        phone.extend_from_slice(&self.request.request_id);
        phone.extend_from_slice(&self.accept.phone_nonce);
        (desktop, phone)
    }

    fn aad(&self) -> Vec<u8> {
        let mut aad = b"padlink/v1/pair-aad".to_vec();
        aad.extend_from_slice(&self.accept.version.to_le_bytes());
        aad.extend_from_slice(&self.accept.suite.to_le_bytes());
        aad.extend_from_slice(&self.request.request_id);
        aad.extend_from_slice(&self.request.desktop_nonce);
        aad.extend_from_slice(&self.accept.phone_nonce);
        aad.extend_from_slice(self.accept.session_id.as_bytes());
        aad.extend_from_slice(&(self.request.desktop_label.len() as u16).to_le_bytes());
        aad.extend_from_slice(self.request.desktop_label.as_bytes());
        aad
    }

    pub fn transcript_salt(&self, pa: &[u8], pb: &[u8]) -> [u8; 32] {
        let mut hash = Sha256::new();
        hash.update(b"padlink/v1/pair-transcript");
        hash.update(self.aad());
        hash.update(pa);
        hash.update(pb);
        hash.finalize().into()
    }

    pub fn start_desktop(
        &self,
        code: &str,
    ) -> Result<([u8; PAKE_POINT_LEN], DesktopPake), ProtocolError> {
        let scalar = password_scalar(code)?;
        let (desktop, phone) = self.identities();
        let mut rng = random::os_rng()?;
        let (point, state) =
            PartyA::<Spake2P256>::start(&scalar, &desktop, &phone, &self.aad(), &mut rng)
                .map_err(|_| ProtocolError::PakeFailed)?;
        Ok((
            point.try_into().map_err(|_| ProtocolError::PakeFailed)?,
            state,
        ))
    }

    pub fn respond_phone(
        &self,
        code: &str,
        pa: &[u8; PAKE_POINT_LEN],
    ) -> Result<([u8; PAKE_POINT_LEN], Spake2Output), ProtocolError> {
        validate_point(pa)?;
        let scalar = password_scalar(code)?;
        let (desktop, phone) = self.identities();
        let mut rng = random::os_rng()?;
        let (point, state) =
            PartyB::<Spake2P256>::start(&scalar, &desktop, &phone, &self.aad(), &mut rng)
                .map_err(|_| ProtocolError::PakeFailed)?;
        let output = state.finish(pa).map_err(|_| ProtocolError::PakeFailed)?;
        Ok((
            point.try_into().map_err(|_| ProtocolError::PakeFailed)?,
            output,
        ))
    }
}

fn password_scalar(
    code: &str,
) -> Result<Zeroizing<<P256Group as CpaceGroup>::Scalar>, ProtocolError> {
    let code = Zeroizing::new(normalize_pairing_code(code)?);
    let mut hash = Sha512::new();
    hash.update(b"padlink/v1/pair-password");
    hash.update(code.as_bytes());
    let wide: Zeroizing<[u8; 64]> = Zeroizing::new(hash.finalize().into());
    P256Group::scalar_from_wide_bytes(wide.as_ref())
        .map(Zeroizing::new)
        .map_err(|_| ProtocolError::PakeFailed)
}

pub(crate) fn validate_point(point: &[u8; PAKE_POINT_LEN]) -> Result<(), ProtocolError> {
    if point[0] != 4 {
        return Err(ProtocolError::PakeFailed);
    }
    let point = P256Group::from_bytes(point).map_err(|_| ProtocolError::PakeFailed)?;
    if point.is_identity() {
        return Err(ProtocolError::PakeFailed);
    }
    Ok(())
}

pub(crate) fn confirmation(output: &Spake2Output) -> Result<[u8; CONFIRMATION_LEN], ProtocolError> {
    output
        .confirmation_mac
        .as_slice()
        .try_into()
        .map_err(|_| ProtocolError::PakeFailed)
}

pub(crate) fn session_root(
    output: &Spake2Output,
    salt: &[u8; 32],
) -> Result<SessionSecret, ProtocolError> {
    if output.session_key.as_bytes().len() != 16 {
        return Err(ProtocolError::PakeFailed);
    }
    let mut bytes = Zeroizing::new([0_u8; 32]);
    Hkdf::<Sha256>::new(Some(salt), output.session_key.as_bytes())
        .expand(b"padlink/v1/session-root", bytes.as_mut())
        .map_err(|_| ProtocolError::PakeFailed)?;
    Ok(SessionSecret::from_bytes(*bytes))
}
