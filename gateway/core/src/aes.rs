//! AES-128 (encryption only) and AES-128-CFB8, the cipher of Minecraft's online mode: key = IV = the shared secret, one block encryption per byte.
//! Table-driven (T-tables built at first use from the S-box), standard library only.  CFB8 encryption is serial inside one stream, so the cost is
//! one block encryption per byte per direction.  The main crate can swap in the `aes` crate's AES-NI blocks behind the same `Cfb8` interface.

use std::sync::OnceLock;

struct Tables {
    sbox: [u8; 256],
    te: [[u32; 256]; 4],
}

fn tables() -> &'static Tables {
    static T: OnceLock<Tables> = OnceLock::new();
    T.get_or_init(|| {
        // The S-box by its definition (multiplicative inverse in GF(2^8) followed by the affine map), the way FIPS-197 defines it.
        let mut sbox = [0u8; 256];
        let (mut p, mut q) = (1u8, 1u8);
        loop {
            p = p ^ (p << 1) ^ if p & 0x80 != 0 { 0x1b } else { 0 }; // p * 3
            q ^= q << 1; // q / 3
            q ^= q << 2;
            q ^= q << 4;
            if q & 0x80 != 0 {
                q ^= 0x09;
            }
            let x = q ^ q.rotate_left(1) ^ q.rotate_left(2) ^ q.rotate_left(3) ^ q.rotate_left(4);
            sbox[p as usize] = x ^ 0x63;
            if p == 1 {
                break;
            }
        }
        sbox[0] = 0x63;
        let xtime = |b: u8| (b << 1) ^ if b & 0x80 != 0 { 0x1b } else { 0 };
        let mut te = [[0u32; 256]; 4];
        for i in 0..256 {
            let s = sbox[i];
            let s2 = xtime(s);
            let s3 = s2 ^ s;
            let w = ((s2 as u32) << 24) | ((s as u32) << 16) | ((s as u32) << 8) | s3 as u32;
            te[0][i] = w;
            te[1][i] = w.rotate_right(8);
            te[2][i] = w.rotate_right(16);
            te[3][i] = w.rotate_right(24);
        }
        Tables { sbox, te }
    })
}

pub struct Aes128 {
    rk: [u32; 44],
}

impl Aes128 {
    pub fn new(key: &[u8; 16]) -> Self {
        let t = tables();
        let mut w = [0u32; 44];
        for i in 0..4 {
            w[i] = u32::from_be_bytes([key[4 * i], key[4 * i + 1], key[4 * i + 2], key[4 * i + 3]]);
        }
        let mut rcon = 1u8;
        for i in 4..44 {
            let mut temp = w[i - 1];
            if i % 4 == 0 {
                temp = temp.rotate_left(8);
                let b = temp.to_be_bytes();
                temp = u32::from_be_bytes([t.sbox[b[0] as usize], t.sbox[b[1] as usize], t.sbox[b[2] as usize], t.sbox[b[3] as usize]]);
                temp ^= (rcon as u32) << 24;
                rcon = (rcon << 1) ^ if rcon & 0x80 != 0 { 0x1b } else { 0 };
            }
            w[i] = w[i - 4] ^ temp;
        }
        Aes128 { rk: w }
    }

    pub fn encrypt_block(&self, block: &[u8; 16]) -> [u8; 16] {
        let t = tables();
        let rk = &self.rk;
        let mut s0 = u32::from_be_bytes([block[0], block[1], block[2], block[3]]) ^ rk[0];
        let mut s1 = u32::from_be_bytes([block[4], block[5], block[6], block[7]]) ^ rk[1];
        let mut s2 = u32::from_be_bytes([block[8], block[9], block[10], block[11]]) ^ rk[2];
        let mut s3 = u32::from_be_bytes([block[12], block[13], block[14], block[15]]) ^ rk[3];
        for r in 1..10 {
            let t0 = t.te[0][(s0 >> 24) as usize] ^ t.te[1][((s1 >> 16) & 0xff) as usize] ^ t.te[2][((s2 >> 8) & 0xff) as usize] ^ t.te[3][(s3 & 0xff) as usize] ^ rk[4 * r];
            let t1 = t.te[0][(s1 >> 24) as usize] ^ t.te[1][((s2 >> 16) & 0xff) as usize] ^ t.te[2][((s3 >> 8) & 0xff) as usize] ^ t.te[3][(s0 & 0xff) as usize] ^ rk[4 * r + 1];
            let t2 = t.te[0][(s2 >> 24) as usize] ^ t.te[1][((s3 >> 16) & 0xff) as usize] ^ t.te[2][((s0 >> 8) & 0xff) as usize] ^ t.te[3][(s1 & 0xff) as usize] ^ rk[4 * r + 2];
            let t3 = t.te[0][(s3 >> 24) as usize] ^ t.te[1][((s0 >> 16) & 0xff) as usize] ^ t.te[2][((s1 >> 8) & 0xff) as usize] ^ t.te[3][(s2 & 0xff) as usize] ^ rk[4 * r + 3];
            s0 = t0;
            s1 = t1;
            s2 = t2;
            s3 = t3;
        }
        let sb = &t.sbox;
        let f = |a: u32, b: u32, c: u32, d: u32, k: u32| -> u32 {
            (((sb[(a >> 24) as usize] as u32) << 24) | ((sb[((b >> 16) & 0xff) as usize] as u32) << 16) | ((sb[((c >> 8) & 0xff) as usize] as u32) << 8) | sb[(d & 0xff) as usize] as u32) ^ k
        };
        let o0 = f(s0, s1, s2, s3, rk[40]);
        let o1 = f(s1, s2, s3, s0, rk[41]);
        let o2 = f(s2, s3, s0, s1, rk[42]);
        let o3 = f(s3, s0, s1, s2, rk[43]);
        let mut out = [0u8; 16];
        out[0..4].copy_from_slice(&o0.to_be_bytes());
        out[4..8].copy_from_slice(&o1.to_be_bytes());
        out[8..12].copy_from_slice(&o2.to_be_bytes());
        out[12..16].copy_from_slice(&o3.to_be_bytes());
        out
    }
}

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
        Self { cipher: Aes128::new(secret), ring, pos: 0 }
    }

    #[inline]
    fn keystream_byte(&self) -> u8 {
        let mut blk = [0u8; 16];
        blk.copy_from_slice(&self.ring[self.pos..self.pos + 16]);
        self.cipher.encrypt_block(&blk)[0]
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

    fn hex(b: &[u8]) -> String {
        b.iter().map(|x| format!("{x:02x}")).collect()
    }

    /// FIPS-197 appendix C.1: key 000102..0f, plaintext 00112233445566778899aabbccddeeff.
    #[test]
    fn fips_197_vector() {
        let key: [u8; 16] = core::array::from_fn(|i| i as u8);
        let pt: [u8; 16] = core::array::from_fn(|i| (i as u8) * 0x11);
        assert_eq!(hex(&Aes128::new(&key).encrypt_block(&pt)), "69c4e0d86a7b0430d8cdb78070b4c55a");
    }

    /// printf 'Hello, dbcraft!' | openssl enc -aes-128-cfb8 -K 000102030405060708090a0b0c0d0e0f -iv 000102030405060708090a0b0c0d0e0f
    #[test]
    fn matches_openssl_cfb8() {
        let key: [u8; 16] = core::array::from_fn(|i| i as u8);
        let mut d = b"Hello, dbcraft!".to_vec();
        Cfb8::new(&key).encrypt(&mut d);
        assert_eq!(hex(&d), "42ea5ed4daf864c3beb1a4c6b71832");
        Cfb8::new(&key).decrypt(&mut d);
        assert_eq!(&d, b"Hello, dbcraft!");
    }

    #[test]
    fn roundtrip_with_arbitrary_chunking() {
        let key = [7u8; 16];
        let plain: Vec<u8> = (0..5000u32).map(|i| (i * 31 + 7) as u8).collect();
        let mut enc = Cfb8::new(&key);
        let mut ct = plain.clone();
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

    /// The same stream cut at different places must give the same ciphertext (state carries over, including across the ring wrap at 1024 bytes).
    #[test]
    fn chunking_does_not_change_the_stream() {
        let key = [0x5au8; 16];
        let plain: Vec<u8> = (0..4096u32).map(|i| (i ^ (i >> 5)) as u8).collect();
        let mut whole = plain.clone();
        Cfb8::new(&key).encrypt(&mut whole);
        let mut cut = plain.clone();
        let mut e = Cfb8::new(&key);
        for chunk in cut.chunks_mut(13) {
            e.encrypt(chunk);
        }
        assert_eq!(whole, cut);
    }
}
