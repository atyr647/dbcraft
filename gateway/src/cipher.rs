//! AES-128-CFB8, the cipher of Minecraft's online mode: key = IV = the shared secret, one AES block per byte.
//! CFB8 encryption is serial inside one stream (each byte needs the previous ciphertext byte), so the cost is one block encryption per byte per direction.

use aes::cipher::{generic_array::GenericArray, BlockEncrypt, KeyInit};
use aes::Aes128;

/// The 16-byte shift register lives in a window of a longer array, so shifting is an index increment instead of a copy per byte.
const RING: usize = 1024;

pub struct Cfb8 {
    cipher: Aes128,
    ring: [u8; RING + 16],
    pos: usize,
}

impl Cfb8 {
    /// Key and IV are the same 16 bytes (the shared secret), as in vanilla.
    pub fn new(secret: &[u8; 16]) -> Self {
        let mut ring = [0u8; RING + 16];
        ring[..16].copy_from_slice(secret);
        Self { cipher: Aes128::new(GenericArray::from_slice(secret)), ring, pos: 0 }
    }

    #[inline]
    fn keystream_byte(&self) -> u8 {
        let mut blk = GenericArray::clone_from_slice(&self.ring[self.pos..self.pos + 16]);
        self.cipher.encrypt_block(&mut blk);
        blk[0]
    }

    #[inline]
    fn feed(&mut self, ciphertext_byte: u8) {
        self.ring[self.pos + 16] = ciphertext_byte;
        self.pos += 1;
        if self.pos == RING {
            self.ring.copy_within(RING..RING + 16, 0);
            self.pos = 0;
        }
    }

    pub fn encrypt(&mut self, data: &mut [u8]) {
        for b in data.iter_mut() {
            let c = *b ^ self.keystream_byte();
            *b = c;
            self.feed(c);
        }
    }

    pub fn decrypt(&mut self, data: &mut [u8]) {
        for b in data.iter_mut() {
            let c = *b;
            *b = c ^ self.keystream_byte();
            self.feed(c);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_with_arbitrary_chunking() {
        let key = [7u8; 16];
        let plain: Vec<u8> = (0..5000u32).map(|i| (i * 31 + 7) as u8).collect();
        let mut enc = Cfb8::new(&key);
        let mut ct = plain.clone();
        // encrypt in uneven chunks
        let mut o = 0;
        for n in [1usize, 2, 3, 17, 100, 1023, 1024, 1025, 700, 1105] {
            let end = (o + n).min(ct.len());
            enc.encrypt(&mut ct[o..end]);
            o = end;
        }
        assert_eq!(o, 5000);
        let mut dec = Cfb8::new(&key);
        let mut back = ct.clone();
        let mut o = 0;
        for n in [5, 4000, 995] {
            let end = (o + n).min(back.len());
            dec.decrypt(&mut back[o..end]);
            o = end;
        }
        assert_eq!(back, plain);
        assert_ne!(ct, plain);
    }

    /// A fixed vector computed with OpenSSL: `printf 'Hello, dbcraft!' | openssl enc -aes-128-cfb8 -K 000102030405060708090a0b0c0d0e0f -iv 000102030405060708090a0b0c0d0e0f | xxd -p`
    /// (the shell test in tests/gateway/cfb8_openssl.sh checks random data against the real `openssl` binary).
    #[test]
    fn matches_openssl_vector() {
        let key: [u8; 16] = core::array::from_fn(|i| i as u8);
        let mut enc = Cfb8::new(&key);
        let mut d = b"Hello, dbcraft!".to_vec();
        enc.encrypt(&mut d);
        let hex: String = d.iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(hex, EXPECTED_HELLO);
    }
    const EXPECTED_HELLO: &str = "42ea5ed4daf864c3beb1a4c6b71832";
}
