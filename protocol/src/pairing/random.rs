//! Operating-system randomness for pairing.
//!
//! The PAKE API takes an infallible `CryptoRng`. We seed a ChaCha20 generator
//! from the OS source so a failed OS read is reported as an error instead of
//! panicking or falling back to a weak generator.

use rand_chacha::ChaCha20Rng;
use rand_core::SeedableRng;
use zeroize::{Zeroize, Zeroizing};

use crate::error::ProtocolError;

/// Fills a fixed-size array from the OS random source.
pub(crate) fn array<const N: usize>() -> Result<[u8; N], ProtocolError> {
    let mut bytes = [0_u8; N];
    getrandom::fill(&mut bytes).map_err(|_| ProtocolError::RandomUnavailable)?;
    Ok(bytes)
}

/// Creates a ChaCha20 CSPRNG seeded from the OS random source.
///
/// The returned generator is used only for one ephemeral PAKE message. The
/// seed is erased before the generator is returned.
pub(crate) fn os_rng() -> Result<ChaCha20Rng, ProtocolError> {
    let mut seed = Zeroizing::new(array::<32>()?);
    let rng = ChaCha20Rng::from_seed(*seed);
    seed.zeroize();
    Ok(rng)
}
