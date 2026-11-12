//! Cross-check: generate with nostr, print nsec; an external pure-python
//! bech32 verifier must confirm checksum and recover the same secret.
use nostr::nips::nip19::ToBech32;

fn main() {
    let keys = nostr::Keys::generate();
    let nsec = keys.secret_key().to_bech32().unwrap();
    println!("{}", nsec);
    println!("{}", keys.public_key().to_hex());
    println!("{}", keys.public_key().to_bech32().unwrap());
}
