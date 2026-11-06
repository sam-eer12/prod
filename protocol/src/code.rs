//! Six-character pairing-code generation, normalization, and attempt limits.
//!
//! This module owns the token *lifecycle*, not the password-authenticated key
//! exchange. The PAKE must consume the token through a reviewed implementation;
//! generating a well-formed code here does not authenticate a peer.

use subtle::ConstantTimeEq;
use zeroize::Zeroizing;

use crate::error::ProtocolError;

/// Number of characters in a pairing token.
pub const PAIRING_CODE_LENGTH: usize = 6;

/// The unambiguous alphabet required by the product specification.
///
/// `I` and `O` are deliberately excluded so the code can be read aloud and
/// typed without confusion.
pub const PAIRING_CODE_ALPHABET: &[u8; 32] = b"23456789ABCDEFGHJKLMNPQRSTUVWXYZ";

/// A phone-generated token remains valid for 60 seconds.
pub const PAIRING_TOKEN_TTL_MS: u64 = 60_000;

/// A token allows at most three failed verification attempts.
pub const PAIRING_MAX_ATTEMPTS: u8 = 3;

/// Returns `true` when `value` is exactly six uppercase alphabet characters.
///
/// This is a shape check only. It does not authenticate a peer.
pub fn is_well_formed_pairing_code(value: &str) -> bool {
    value.len() == PAIRING_CODE_LENGTH
        && value
            .bytes()
            .all(|byte| PAIRING_CODE_ALPHABET.contains(&byte))
}

/// Normalizes user input into the canonical six-character form.
///
/// Matching is case-insensitive. ASCII whitespace, `-`, and `_` separators are
/// ignored so a code copied from the phone can be typed naturally. Every other
/// character, including the ambiguous `I`, `O`, `0`, and `1`, is rejected.
pub fn normalize_pairing_code(input: &str) -> Result<String, ProtocolError> {
    let mut normalized = String::with_capacity(PAIRING_CODE_LENGTH);

    for character in input.chars() {
        if character.is_ascii_whitespace() || character == '-' || character == '_' {
            continue;
        }

        let candidate = character.to_ascii_uppercase();
        if !candidate.is_ascii() || !PAIRING_CODE_ALPHABET.contains(&(candidate as u8)) {
            return Err(ProtocolError::InvalidPairingCode);
        }

        normalized.push(candidate);
        if normalized.len() > PAIRING_CODE_LENGTH {
            return Err(ProtocolError::InvalidPairingCode);
        }
    }

    if normalized.len() != PAIRING_CODE_LENGTH {
        return Err(ProtocolError::InvalidPairingCode);
    }

    Ok(normalized)
}

/// Generates a uniformly sampled six-character pairing code.
///
/// Each byte maps to one of 32 symbols with `byte & 0x1F`. This is uniform
/// because 32 divides 256; no modulo bias is introduced.
pub fn generate_pairing_code() -> Result<String, ProtocolError> {
    let mut random = [0_u8; PAIRING_CODE_LENGTH];
    getrandom::fill(&mut random).map_err(|_| ProtocolError::RandomUnavailable)?;

    Ok(random
        .iter()
        .map(|byte| PAIRING_CODE_ALPHABET[(byte & 0x1F) as usize] as char)
        .collect())
}

/// A consented, short-lived pairing token with a bounded attempt budget.
///
/// The plaintext code is retained only for the life of the token and is zeroed
/// on drop or invalidation. Call [`PairingToken::check`] for every submitted
/// code, including malformed input, so attempts cannot be replenished by
/// reconnecting.
pub struct PairingToken {
    code: Option<Zeroizing<String>>,
    expires_at_ms: u64,
    attempts_remaining: u8,
}

impl PairingToken {
    /// Issues a token from the operating system random source.
    pub fn issue(now_ms: u64) -> Result<Self, ProtocolError> {
        Self::issue_with_code(generate_pairing_code()?, now_ms)
    }

    fn issue_with_code(code: String, now_ms: u64) -> Result<Self, ProtocolError> {
        if !is_well_formed_pairing_code(&code) {
            return Err(ProtocolError::InvalidPairingCode);
        }

        let expires_at_ms =
            now_ms
                .checked_add(PAIRING_TOKEN_TTL_MS)
                .ok_or(ProtocolError::ValueOutOfRange {
                    field: "expires_at_ms",
                })?;

        Ok(Self {
            code: Some(Zeroizing::new(code)),
            expires_at_ms,
            attempts_remaining: PAIRING_MAX_ATTEMPTS,
        })
    }

    /// Absolute monotonic deadline in milliseconds.
    pub const fn expires_at_ms(&self) -> u64 {
        self.expires_at_ms
    }

    /// The code to display on the phone's consent screen.
    ///
    /// Never log, persist, or include this value in an argument or QR payload.
    pub fn display_code(&self) -> Option<&str> {
        self.code.as_deref().map(String::as_str)
    }

    /// Remaining verification attempts.
    pub const fn attempts_remaining(&self) -> u8 {
        self.attempts_remaining
    }

    /// Returns whether the token can still be used at `now_ms`.
    pub fn is_live(&self, now_ms: u64) -> bool {
        self.code.is_some() && now_ms < self.expires_at_ms
    }

    /// Verifies a submitted code and consumes one attempt on failure.
    ///
    /// Success, expiry, or the third failure invalidates the token. The caller
    /// must discard it and require fresh phone consent before another attempt.
    pub fn check(&mut self, candidate: &str, now_ms: u64) -> Result<(), ProtocolError> {
        if self.code.is_none() {
            return Err(ProtocolError::PairingTokenLocked);
        }
        if now_ms >= self.expires_at_ms {
            self.invalidate();
            return Err(ProtocolError::PairingTokenExpired);
        }

        let Ok(normalized) = normalize_pairing_code(candidate) else {
            return Err(self.record_failure());
        };

        let matches = self
            .code
            .as_ref()
            .is_some_and(|code| bool::from(code.as_bytes().ct_eq(normalized.as_bytes())));

        if matches {
            self.invalidate();
            Ok(())
        } else {
            Err(self.record_failure())
        }
    }

    /// Erases the token immediately.
    pub fn invalidate(&mut self) {
        self.code = None;
        self.attempts_remaining = 0;
    }

    fn record_failure(&mut self) -> ProtocolError {
        self.attempts_remaining = self.attempts_remaining.saturating_sub(1);
        if self.attempts_remaining == 0 {
            self.invalidate();
            ProtocolError::PairingTokenLocked
        } else {
            ProtocolError::PairingCodeMismatch {
                attempts_remaining: self.attempts_remaining,
            }
        }
    }
}

impl std::fmt::Debug for PairingToken {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("PairingToken")
            .field("expires_at_ms", &self.expires_at_ms)
            .field("attempts_remaining", &self.attempts_remaining)
            .field("live", &self.code.is_some())
            .finish_non_exhaustive()
    }
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

    #[test]
    fn normalizes_case_and_separators() {
        assert_eq!(normalize_pairing_code("7k4-m2q").unwrap(), "7K4M2Q");
        assert_eq!(normalize_pairing_code(" 7K4 M2Q ").unwrap(), "7K4M2Q");
        assert_eq!(normalize_pairing_code("7K4_M2Q").unwrap(), "7K4M2Q");
        assert_eq!(normalize_pairing_code("7K4M2Q").unwrap(), "7K4M2Q");
    }

    #[test]
    fn rejects_invalid_normalized_input() {
        assert_eq!(
            normalize_pairing_code("7K4M2QI"),
            Err(ProtocolError::InvalidPairingCode)
        );
        assert_eq!(
            normalize_pairing_code("7K4M2"),
            Err(ProtocolError::InvalidPairingCode)
        );
        assert_eq!(
            normalize_pairing_code("7K4M20"),
            Err(ProtocolError::InvalidPairingCode)
        );
        assert_eq!(
            normalize_pairing_code("7K4M2!"),
            Err(ProtocolError::InvalidPairingCode)
        );
        assert_eq!(
            normalize_pairing_code("7K4M2Q💥"),
            Err(ProtocolError::InvalidPairingCode)
        );
    }

    #[test]
    fn generated_codes_are_well_formed() {
        for _ in 0..128 {
            let code = generate_pairing_code().unwrap();
            assert!(is_well_formed_pairing_code(&code), "{code}");
        }
    }

    #[test]
    fn token_accepts_case_insensitive_success_once() {
        let mut token = PairingToken::issue_with_code("7K4M2Q".to_owned(), 1_000).unwrap();
        assert_eq!(token.display_code(), Some("7K4M2Q"));
        assert_eq!(token.expires_at_ms(), 61_000);
        assert!(token.check("7k4-m2q", 1_001).is_ok());
        assert!(!token.is_live(1_001));
        assert_eq!(token.display_code(), None);
        assert_eq!(
            token.check("7K4M2Q", 1_002),
            Err(ProtocolError::PairingTokenLocked)
        );
    }

    #[test]
    fn token_locks_after_three_failures_even_for_correct_code() {
        let mut token = PairingToken::issue_with_code("7K4M2Q".to_owned(), 0).unwrap();

        assert_eq!(
            token.check("AAAAAA", 1),
            Err(ProtocolError::PairingCodeMismatch {
                attempts_remaining: 2
            })
        );
        assert_eq!(
            token.check("BBBBBB", 2),
            Err(ProtocolError::PairingCodeMismatch {
                attempts_remaining: 1
            })
        );
        assert_eq!(
            token.check("CCCCCC", 3),
            Err(ProtocolError::PairingTokenLocked)
        );
        assert_eq!(
            token.check("7K4M2Q", 4),
            Err(ProtocolError::PairingTokenLocked)
        );
    }

    #[test]
    fn malformed_input_counts_as_an_attempt() {
        let mut token = PairingToken::issue_with_code("7K4M2Q".to_owned(), 0).unwrap();
        assert_eq!(
            token.check("short", 1),
            Err(ProtocolError::PairingCodeMismatch {
                attempts_remaining: 2
            })
        );
    }

    #[test]
    fn token_expires_at_exact_deadline() {
        let mut token = PairingToken::issue_with_code("7K4M2Q".to_owned(), 50).unwrap();
        assert!(token.check("7K4M2Q", 60_049).is_ok());

        let mut expired = PairingToken::issue_with_code("7K4M2Q".to_owned(), 0).unwrap();
        assert_eq!(
            expired.check("7K4M2Q", PAIRING_TOKEN_TTL_MS),
            Err(ProtocolError::PairingTokenExpired)
        );
        assert!(!expired.is_live(PAIRING_TOKEN_TTL_MS));
    }

    #[test]
    fn cancellation_invalidates_token() {
        let mut token = PairingToken::issue_with_code("7K4M2Q".to_owned(), 0).unwrap();
        token.invalidate();
        assert_eq!(
            token.check("7K4M2Q", 1),
            Err(ProtocolError::PairingTokenLocked)
        );
    }
}
