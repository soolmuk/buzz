//! Core key-generation pipeline for `nsec-keygen`.
//!
//! Pure logic, no windowing: generate a secret key, derive the public key,
//! encode nsec/npub bech32, and render the backup file contents. Unit-tested
//! and reused by the GUI and the `--self-test` smoke mode.

use nostr::key::SecretKey;
use nostr::nips::nip19::{FromBech32, ToBech32};
use nostr::Keys;
use std::fmt::Write as _;

/// One generated identity.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GeneratedKey {
    pub secret_hex: String,
    pub nsec: String,
    pub pubkey_hex: String,
    pub npub: String,
}

/// Generate a fresh random keypair and encode all wire forms.
pub fn generate() -> GeneratedKey {
    let keys = Keys::generate();
    from_secret(keys.secret_key())
}

/// Derive all encodings from an existing secret key (used by tests and by
/// re-deriving from a known nsec to verify round-trip).
pub fn from_secret(secret: &SecretKey) -> GeneratedKey {
    let keys = Keys::new(secret.clone());
    let pubkey = keys.public_key();
    GeneratedKey {
        secret_hex: secret.to_secret_hex(),
        nsec: secret.to_bech32().expect("nsec encode"),
        pubkey_hex: pubkey.to_hex(),
        npub: pubkey.to_bech32().expect("npub encode"),
    }
}

/// Parse an nsec1 string back into a [`GeneratedKey`] (round-trip check).
pub fn parse_nsec(nsec: &str) -> Result<GeneratedKey, String> {
    let secret = SecretKey::from_bech32(nsec.trim()).map_err(|e| format!("invalid nsec: {e}"))?;
    Ok(from_secret(&secret))
}

/// Render the backup file body for `name`.
///
/// The file deliberately contains both the nsec (for direct import into the
/// Buzz desktop app) and the hex secret (for CLI/tools), plus the npub so the
/// operator can hand out their public ID without opening the app.
pub fn render_backup_file(name: &str, key: &GeneratedKey) -> String {
    let mut out = String::new();
    let _ = writeln!(out, "# Buzz offline — Nostr identity backup");
    let _ = writeln!(out, "# name: {name}");
    let _ = writeln!(out, "# generated: (offline, local RNG)");
    let _ = writeln!(out);
    let _ = writeln!(out, "nsec:  {}", key.nsec);
    let _ = writeln!(out, "hex:   {}", key.secret_hex);
    let _ = writeln!(out);
    let _ = writeln!(out, "npub:  {}", key.npub);
    let _ = writeln!(out, "pubkey hex: {}", key.pubkey_hex);
    let _ = writeln!(out);
    let _ = writeln!(
        out,
        "# Import into Buzz desktop 1.0.0: Other options → Join a community → Continue →"
    );
    let _ = writeln!(
        out,
        "#   \"Use an existing key\" → paste the nsec line above → Continue with this key."
    );
    let _ = writeln!(out, "# Keep this file secret. Anyone with the nsec signs in as you.");
    out
}

/// Suggested backup file name for `name` (sanitized, `.key.txt` suffix).
pub fn backup_filename(name: &str) -> String {
    let mut safe = String::new();
    for c in name.trim().chars() {
        if c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.' {
            safe.push(c);
        } else {
            safe.push('_');
        }
    }
    if safe.is_empty() {
        safe.push_str("identity");
    }
    format!("{safe}.key.txt")
}

/// Write the backup file with owner-only permissions on Unix, best-effort on
/// Windows (ACL hardening is left to the operator). Returns the path written.
pub fn write_backup(dir: &std::path::Path, name: &str, key: &GeneratedKey) -> std::io::Result<std::path::PathBuf> {
    let path = dir.join(backup_filename(name));
    std::fs::write(&path, render_backup_file(name, key))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
    }
    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generated_key_roundtrips_through_nsec() {
        let key = generate();
        assert!(key.nsec.starts_with("nsec1"));
        assert_eq!(key.nsec.len(), 63);
        assert_eq!(key.secret_hex.len(), 64);
        assert_eq!(key.pubkey_hex.len(), 64);
        assert!(key.npub.starts_with("npub1"));

        let back = parse_nsec(&key.nsec).expect("parse own nsec");
        assert_eq!(back, key, "nsec round-trip must be lossless");
    }

    #[test]
    fn two_generations_differ() {
        let a = generate();
        let b = generate();
        assert_ne!(a.secret_hex, b.secret_hex);
        assert_ne!(a.pubkey_hex, b.pubkey_hex);
    }

    #[test]
    fn npub_matches_pubkey_hex() {
        // Derive npub from raw pubkey hex independently and compare.
        let key = generate();
        let pk = nostr::PublicKey::from_hex(&key.pubkey_hex).expect("hex pubkey");
        assert_eq!(pk.to_bech32().unwrap(), key.npub);
    }

    #[test]
    fn parse_rejects_garbage() {
        assert!(parse_nsec("nsec1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq").is_err());
        assert!(parse_nsec("hello").is_err());
        assert!(parse_nsec("npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq").is_err());
    }

    #[test]
    fn backup_file_contains_all_forms_and_name() {
        let key = generate();
        let body = render_backup_file("alice", &key);
        assert!(body.contains("name: alice"));
        assert!(body.contains(&key.nsec));
        assert!(body.contains(&key.secret_hex));
        assert!(body.contains(&key.npub));
    }

    #[test]
    fn filename_is_sanitized() {
        assert_eq!(backup_filename("alice"), "alice.key.txt");
        assert_eq!(backup_filename("a b/c\\d:e"), "a_b_c_d_e.key.txt");
        assert_eq!(backup_filename("   "), "identity.key.txt");
    }

    #[test]
    fn write_backup_creates_file() {
        let dir = std::env::temp_dir().join(format!("nsec-keygen-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let key = generate();
        let path = write_backup(&dir, "bob", &key).unwrap();
        let body = std::fs::read_to_string(&path).unwrap();
        assert_eq!(parse_nsec(&key.nsec).unwrap(), key);
        assert!(body.contains(&key.nsec));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
