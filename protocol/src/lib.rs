//! Shared PadLink protocol primitives.
//!
//! This crate is intentionally a scaffold. It currently exposes only the
//! constants that both peers must agree on. Pairing, key derivation, packet
//! framing, replay protection, and the input journal are not implemented yet.
//!
//! See `protocol/SPEC.md` for the (still draft) normative specification.

/// Wire protocol revision. Bump when a change breaks interoperability.
pub const PROTOCOL_VERSION: u16 = 0;

/// Number of characters in a pairing token.
pub const PAIRING_CODE_LENGTH: usize = 6;

/// The unambiguous alphabet required by the product specification.
///
/// `I` and `O` are deliberately excluded so the code can be read aloud and
/// typed without confusion.
pub const PAIRING_CODE_ALPHABET: &[u8; 32] = b"23456789ABCDEFGHJKLMNPQRSTUVWXYZ";

/// Returns `true` when `value` is a well-formed pairing code.
///
/// This is a shape check only. It does not generate, authenticate, or verify a
/// token; a reviewed PAKE implementation will own that behavior.
pub fn is_well_formed_pairing_code(value: &str) -> bool {
    value.len() == PAIRING_CODE_LENGTH
        && value
            .bytes()
            .all(|byte| PAIRING_CODE_ALPHABET.contains(&byte))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn alphabet_has_no_duplicates() {
        let mut seen = [false; 256];
        for byte in PAIRING_CODE_ALPHABET {
            assert!(!seen[*byte as usize], "duplicate alphabet entry");
            seen[*byte as usize] = true;
        }
    }

    #[test]
    fn accepts_a_valid_code() {
        assert!(is_well_formed_pairing_code("7K4M2Q"));
    }

    #[test]
    fn rejects_ambiguous_or_invalid_codes() {
        assert!(!is_well_formed_pairing_code("7K4M2"));
        assert!(!is_well_formed_pairing_code("7K4M2QI"));
        assert!(!is_well_formed_pairing_code("7k4m2q"));
        assert!(!is_well_formed_pairing_code("7K4M20"));
    }
}
