//! Minecraft's server hash: SHA-1 over serverId + shared secret + public key, printed as Java's `new BigInteger(digest).toString(16)`:
//! the digest is read as a SIGNED big-endian number, so a digest starting with a bit 1 is printed with a minus sign and its two's complement.

use crate::sha1::sha1;

pub fn digest_to_signed_hex(digest: &[u8; 20]) -> String {
    let mut d = *digest;
    let neg = d[0] & 0x80 != 0;
    if neg {
        let mut carry = 1u16;
        for b in d.iter_mut().rev() {
            let v = (!*b) as u16 + carry;
            *b = v as u8;
            carry = v >> 8;
        }
    }
    let hex: String = d.iter().map(|b| format!("{b:02x}")).collect();
    let t = hex.trim_start_matches('0');
    let t = if t.is_empty() { "0" } else { t };
    if neg {
        format!("-{t}")
    } else {
        t.to_string()
    }
}

/// `server_id` is empty in 1.7+ servers; `secret` is the 16-byte shared secret; `public_key_der` is the X.509 SubjectPublicKeyInfo the server sent.
pub fn server_hash(server_id: &str, secret: &[u8], public_key_der: &[u8]) -> String {
    let mut data = Vec::with_capacity(server_id.len() + secret.len() + public_key_der.len());
    data.extend_from_slice(server_id.as_bytes());
    data.extend_from_slice(secret);
    data.extend_from_slice(public_key_der);
    digest_to_signed_hex(&sha1(&data))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The published examples (wiki.vg "Protocol Encryption"): the hash of the bare strings.
    #[test]
    fn published_examples() {
        assert_eq!(digest_to_signed_hex(&sha1(b"Notch")), "4ed1f46bbe04bc756bcb17c0c7ce3e4632f06a48");
        assert_eq!(digest_to_signed_hex(&sha1(b"jeb_")), "-7c9d5b0044c130109a5d7b5fb5c317c02b4e28c1");
        assert_eq!(digest_to_signed_hex(&sha1(b"simon")), "88e16a1019277b15d58faf0541e11910eb756f6");
    }

    #[test]
    fn zero_and_all_ones() {
        assert_eq!(digest_to_signed_hex(&[0u8; 20]), "0");
        // -1: all bits set -> two's complement is 1
        assert_eq!(digest_to_signed_hex(&[0xffu8; 20]), "-1");
        // leading zeros are trimmed in the positive case
        let mut d = [0u8; 20];
        d[19] = 0x2a;
        assert_eq!(digest_to_signed_hex(&d), "2a");
    }

    #[test]
    fn server_hash_concatenates_in_order() {
        let a = server_hash("", &[1u8; 16], &[2u8; 20]);
        let mut cat = vec![1u8; 16];
        cat.extend_from_slice(&[2u8; 20]);
        assert_eq!(a, digest_to_signed_hex(&sha1(&cat)));
        assert_ne!(a, server_hash("x", &[1u8; 16], &[2u8; 20]));
    }
}
