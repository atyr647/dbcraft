//! zlib / deflate decompression (RFC 1950 / 1951), standard library only, with a hard output limit (the guard against decompression bombs).
//! A canonical-Huffman decoder in the style of zlib's `puff.c`: small and easy to check, not fast.  The gateway inflates only the rare large
//! packets a client compresses (the database does all outbound compression), so clarity beats speed here.

type R<T> = Result<T, &'static str>;

struct Bits<'a> {
    d: &'a [u8],
    pos: usize,
    buf: u32,
    cnt: u32,
}

impl<'a> Bits<'a> {
    fn bits(&mut self, need: u32) -> R<u32> {
        let mut val = self.buf;
        while self.cnt < need {
            if self.pos >= self.d.len() {
                return Err("truncated deflate stream");
            }
            val |= (self.d[self.pos] as u32) << self.cnt;
            self.pos += 1;
            self.cnt += 8;
        }
        self.buf = if need >= 32 { 0 } else { val >> need };
        self.cnt -= need;
        Ok(val & (((1u64 << need) - 1) as u32))
    }
}

struct Huffman {
    count: [u16; 16],
    symbol: Vec<u16>,
}

/// Builds a canonical code from code lengths.  Returns the table and `left`: 0 for a complete code, > 0 for an incomplete one; over-subscribed is an error.
fn construct(lengths: &[u8]) -> R<(Huffman, i32)> {
    let mut count = [0u16; 16];
    for &l in lengths {
        count[l as usize] += 1;
    }
    let mut h = Huffman { count, symbol: vec![0; lengths.len()] };
    if count[0] as usize == lengths.len() {
        return Ok((h, 0));
    }
    let mut left: i32 = 1;
    for len in 1..16 {
        left <<= 1;
        left -= count[len] as i32;
        if left < 0 {
            return Err("over-subscribed code");
        }
    }
    let mut offs = [0u16; 16];
    for len in 1..15 {
        offs[len + 1] = offs[len] + count[len];
    }
    for (sym, &l) in lengths.iter().enumerate() {
        if l != 0 {
            h.symbol[offs[l as usize] as usize] = sym as u16;
            offs[l as usize] += 1;
        }
    }
    Ok((h, left))
}

fn decode(b: &mut Bits, h: &Huffman) -> R<u16> {
    let (mut code, mut first, mut index) = (0i32, 0i32, 0i32);
    for len in 1..16 {
        code |= b.bits(1)? as i32;
        let count = h.count[len] as i32;
        if code - count < first {
            return Ok(h.symbol[(index + (code - first)) as usize]);
        }
        index += count;
        first += count;
        first <<= 1;
        code <<= 1;
    }
    Err("invalid Huffman code")
}

const LBASE: [u16; 29] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258];
const LEXT: [u8; 29] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];
const DBASE: [u16; 30] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577];
const DEXT: [u8; 30] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];

fn codes(b: &mut Bits, out: &mut Vec<u8>, limit: usize, lencode: &Huffman, distcode: &Huffman) -> R<()> {
    loop {
        let sym = decode(b, lencode)? as usize;
        if sym < 256 {
            if out.len() >= limit {
                return Err("output limit exceeded");
            }
            out.push(sym as u8);
        } else if sym == 256 {
            return Ok(());
        } else {
            let s = sym - 257;
            if s >= 29 {
                return Err("invalid length code");
            }
            let len = LBASE[s] as usize + b.bits(LEXT[s] as u32)? as usize;
            let ds = decode(b, distcode)? as usize;
            if ds >= 30 {
                return Err("invalid distance code");
            }
            let dist = DBASE[ds] as usize + b.bits(DEXT[ds] as u32)? as usize;
            if dist > out.len() {
                return Err("distance too far back");
            }
            if out.len() + len > limit {
                return Err("output limit exceeded");
            }
            for _ in 0..len {
                let c = out[out.len() - dist];
                out.push(c);
            }
        }
    }
}

fn fixed_tables() -> R<(Huffman, Huffman)> {
    let mut l = [0u8; 288];
    for (i, v) in l.iter_mut().enumerate() {
        *v = match i {
            0..=143 => 8,
            144..=255 => 9,
            256..=279 => 7,
            _ => 8,
        };
    }
    let (lc, _) = construct(&l)?;
    let (dc, _) = construct(&[5u8; 30])?;
    Ok((lc, dc))
}

fn dynamic_tables(b: &mut Bits) -> R<(Huffman, Huffman)> {
    const ORDER: [usize; 19] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];
    let nlen = b.bits(5)? as usize + 257;
    let ndist = b.bits(5)? as usize + 1;
    let ncode = b.bits(4)? as usize + 4;
    if nlen > 286 || ndist > 30 {
        return Err("too many length or distance codes");
    }
    let mut lengths = [0u8; 320];
    for &o in ORDER.iter().take(ncode) {
        lengths[o] = b.bits(3)? as u8;
    }
    let (lencode, left) = construct(&lengths[..19])?;
    if left != 0 {
        return Err("incomplete code-length code");
    }
    let mut lengths = [0u8; 320];
    let mut index = 0;
    while index < nlen + ndist {
        let sym = decode(b, &lencode)?;
        if sym < 16 {
            lengths[index] = sym as u8;
            index += 1;
        } else {
            let (prev, rep) = match sym {
                16 => {
                    if index == 0 {
                        return Err("repeat with no previous length");
                    }
                    (lengths[index - 1], 3 + b.bits(2)? as usize)
                }
                17 => (0, 3 + b.bits(3)? as usize),
                _ => (0, 11 + b.bits(7)? as usize),
            };
            if index + rep > nlen + ndist {
                return Err("too many code lengths");
            }
            for _ in 0..rep {
                lengths[index] = prev;
                index += 1;
            }
        }
    }
    if lengths[256] == 0 {
        return Err("no end-of-block code");
    }
    let (lc, left) = construct(&lengths[..nlen])?;
    if left > 0 && nlen != (lc.count[0] + lc.count[1]) as usize {
        return Err("incomplete literal/length code");
    }
    let (dc, left) = construct(&lengths[nlen..nlen + ndist])?;
    if left > 0 && ndist != (dc.count[0] + dc.count[1]) as usize {
        return Err("incomplete distance code");
    }
    Ok((lc, dc))
}

/// Raw deflate.  Returns the output and the number of input bytes consumed.
pub fn inflate_raw(data: &[u8], limit: usize) -> R<(Vec<u8>, usize)> {
    let mut b = Bits { d: data, pos: 0, buf: 0, cnt: 0 };
    let mut out: Vec<u8> = Vec::with_capacity(limit.min(1 << 16));
    loop {
        let last = b.bits(1)?;
        match b.bits(2)? {
            0 => {
                b.buf = 0;
                b.cnt = 0;
                if b.pos + 4 > data.len() {
                    return Err("truncated stored block");
                }
                let len = u16::from_le_bytes([data[b.pos], data[b.pos + 1]]) as usize;
                let nlen = u16::from_le_bytes([data[b.pos + 2], data[b.pos + 3]]) as usize;
                if len != (!nlen & 0xffff) {
                    return Err("stored block length check");
                }
                b.pos += 4;
                if b.pos + len > data.len() {
                    return Err("truncated stored block");
                }
                if out.len() + len > limit {
                    return Err("output limit exceeded");
                }
                out.extend_from_slice(&data[b.pos..b.pos + len]);
                b.pos += len;
            }
            1 => {
                let (lc, dc) = fixed_tables()?;
                codes(&mut b, &mut out, limit, &lc, &dc)?;
            }
            2 => {
                let (lc, dc) = dynamic_tables(&mut b)?;
                codes(&mut b, &mut out, limit, &lc, &dc)?;
            }
            _ => return Err("invalid block type"),
        }
        if last == 1 {
            break;
        }
    }
    Ok((out, b.pos))
}

pub fn adler32(data: &[u8]) -> u32 {
    let (mut a, mut b) = (1u32, 0u32);
    for chunk in data.chunks(5552) {
        for &x in chunk {
            a += x as u32;
            b += a;
        }
        a %= 65521;
        b %= 65521;
    }
    (b << 16) | a
}

/// A zlib stream: 2-byte header, deflate data, Adler-32.  `limit` bounds the output.
pub fn zlib_decompress(data: &[u8], limit: usize) -> R<Vec<u8>> {
    if data.len() < 6 {
        return Err("zlib stream too short");
    }
    let (cmf, flg) = (data[0], data[1]);
    if cmf & 0x0f != 8 || cmf >> 4 > 7 {
        return Err("unsupported zlib method");
    }
    if (((cmf as u16) << 8) | flg as u16) % 31 != 0 {
        return Err("zlib header check");
    }
    if flg & 0x20 != 0 {
        return Err("preset dictionary");
    }
    let (out, used) = inflate_raw(&data[2..], limit)?;
    let tail = &data[2 + used..];
    if tail.len() < 4 {
        return Err("missing checksum");
    }
    let want = u32::from_be_bytes([tail[0], tail[1], tail[2], tail[3]]);
    if adler32(&out) != want {
        return Err("checksum mismatch");
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stored_block() {
        // zlib of "hello" at level 0: header, stored block (final), adler
        let z = [0x78u8, 0x01, 0x01, 0x05, 0x00, 0xfa, 0xff, b'h', b'e', b'l', b'l', b'o', 0x06, 0x2c, 0x02, 0x15];
        assert_eq!(zlib_decompress(&z, 100).unwrap(), b"hello");
    }

    #[test]
    fn limit_is_enforced() {
        let z = [0x78u8, 0x01, 0x01, 0x05, 0x00, 0xfa, 0xff, b'h', b'e', b'l', b'l', b'o', 0x06, 0x2c, 0x02, 0x15];
        assert!(zlib_decompress(&z, 4).is_err());
    }

    #[test]
    fn bad_checksum_and_truncation() {
        let mut z = vec![0x78u8, 0x01, 0x01, 0x05, 0x00, 0xfa, 0xff, b'h', b'e', b'l', b'l', b'o', 0x06, 0x2c, 0x02, 0x15];
        z[15] ^= 1;
        assert!(zlib_decompress(&z, 100).is_err());
        assert!(zlib_decompress(&z[..10], 100).is_err());
    }

    #[test]
    fn garbage_never_panics() {
        let mut x = 12345u32;
        for n in 0..2000usize {
            let mut d = Vec::new();
            for _ in 0..(n % 60) {
                x = x.wrapping_mul(1103515245).wrapping_add(12345);
                d.push((x >> 16) as u8);
            }
            let _ = zlib_decompress(&d, 4096);
            let _ = inflate_raw(&d, 4096);
        }
    }
}
