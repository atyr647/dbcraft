//! The one packet the gateway parses: the login `key` packet (serverbound), `[VarInt packet id][byte array: RSA(shared secret)][byte array: RSA(verify token)]`,
//! where a byte array is `[VarInt length][bytes]`.  Vanilla's decoder reads exactly these two arrays and rejects trailing bytes; so does this one.

use dbcraft_gateway_core::frame::read_varint;

/// An RSA ciphertext is at most as long as the modulus; 512 bytes covers keys up to 4096 bits.
pub const MAX_ARRAY: usize = 512;

fn field(body: &[u8], o: usize) -> Result<(&[u8], usize), &'static str> {
    let (n, used) = match read_varint(&body[o..]) {
        Ok(Some(x)) => x,
        Ok(None) => return Err("truncated array length"),
        Err(_) => return Err("bad array length"),
    };
    let n = n as usize;
    let start = o + used;
    if n > MAX_ARRAY {
        return Err("array too long");
    }
    if start + n > body.len() {
        return Err("truncated array");
    }
    Ok((&body[start..start + n], start + n))
}

/// Returns (encrypted shared secret, encrypted verify token).
pub fn parse_key_packet(body: &[u8], expected_id: u32) -> Result<(&[u8], &[u8]), &'static str> {
    let (pid, o) = match read_varint(body) {
        Ok(Some(x)) => x,
        _ => return Err("bad packet id"),
    };
    if pid != expected_id {
        return Err("not the key packet");
    }
    let (secret, o) = field(body, o)?;
    let (token, o) = field(body, o)?;
    if o != body.len() {
        return Err("trailing bytes");
    }
    Ok((secret, token))
}

#[cfg(test)]
pub fn build_key_packet(id: u32, secret_ct: &[u8], token_ct: &[u8]) -> Vec<u8> {
    use dbcraft_gateway_core::frame::write_varint;
    let mut v = Vec::new();
    write_varint(id, &mut v);
    write_varint(secret_ct.len() as u32, &mut v);
    v.extend_from_slice(secret_ct);
    write_varint(token_ct.len() as u32, &mut v);
    v.extend_from_slice(token_ct);
    v
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_the_two_arrays() {
        let p = build_key_packet(1, &[1u8; 128], &[2u8; 128]);
        let (a, b) = parse_key_packet(&p, 1).unwrap();
        assert_eq!(a, &[1u8; 128][..]);
        assert_eq!(b, &[2u8; 128][..]);
    }

    #[test]
    fn rejects_everything_else() {
        let good = build_key_packet(1, &[1u8; 128], &[2u8; 128]);
        assert!(parse_key_packet(&good, 2).is_err(), "another packet id");
        assert!(parse_key_packet(&good[..good.len() - 1], 1).is_err(), "truncated");
        let mut trailing = good.clone();
        trailing.push(0);
        assert!(parse_key_packet(&trailing, 1).is_err(), "trailing byte");
        assert!(parse_key_packet(&[], 1).is_err());
        assert!(parse_key_packet(&[1], 1).is_err(), "no arrays");
        let big = build_key_packet(1, &vec![1u8; MAX_ARRAY + 1], &[2u8; 4]);
        assert!(parse_key_packet(&big, 1).is_err(), "oversized array");
        // a length that claims more than the body holds
        assert!(parse_key_packet(&[1, 0x7f], 1).is_err());
    }

    #[test]
    fn random_bytes_never_panic() {
        let mut s = 5u64;
        for _ in 0..5000 {
            s = s.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            let n = (s >> 40) as usize % 40;
            let b: Vec<u8> = (0..n)
                .map(|_| {
                    s = s.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                    (s >> 33) as u8
                })
                .collect();
            let _ = parse_key_packet(&b, 1);
        }
    }
}
