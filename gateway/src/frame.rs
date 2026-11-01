//! Frame splitting and inbound decompression, with adacraft's rules (adacraft/docs/PROTOCOL.md):
//! the length is a VarInt of at most 3 bytes (value at most 2,097,151); an overlong encoding (a multi-byte value whose last group is 0) is
//! rejected; a length of 0 is rejected; a length above the connection's limit is rejected instead of waited for.  A frame that is merely
//! incomplete returns `None` and consumes nothing.
//!
//! The gateway never parses packets: a frame is handed to the database as it is, minus its length prefix.

use bytes::{Bytes, BytesMut};
use std::io::Read;

/// Largest frame the length field can express (3-byte VarInt).
pub const MAX_FRAME: usize = 2_097_151;
/// Vanilla's limit for a decompressed packet.
pub const MAX_INFLATED: usize = 8_388_608;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FrameError {
    /// A multi-byte length whose last group is 0.
    Overlong,
    /// Three continuation bytes: the length is longer than 3 bytes.
    TooLong,
    ZeroLength,
    /// The announced length exceeds the limit for this connection's state.
    TooLarge(usize),
    Compression(&'static str),
}

impl std::fmt::Display for FrameError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FrameError::Overlong => write!(f, "overlong length VarInt"),
            FrameError::TooLong => write!(f, "length VarInt longer than 3 bytes"),
            FrameError::ZeroLength => write!(f, "frame of length 0"),
            FrameError::TooLarge(n) => write!(f, "frame of {n} bytes exceeds the limit"),
            FrameError::Compression(m) => write!(f, "bad compressed frame: {m}"),
        }
    }
}
impl std::error::Error for FrameError {}

/// Reads a frame-length VarInt.  `Ok(None)` = the buffer ends inside it.
pub fn read_len_varint(b: &[u8]) -> Result<Option<(usize, usize)>, FrameError> {
    let mut v = 0usize;
    for i in 0..3 {
        if i >= b.len() {
            return Ok(None);
        }
        let c = b[i];
        v |= ((c & 0x7f) as usize) << (7 * i);
        if c & 0x80 == 0 {
            if i > 0 && c == 0 {
                return Err(FrameError::Overlong);
            }
            return Ok(Some((v, i + 1)));
        }
    }
    Err(FrameError::TooLong)
}

/// Reads a general VarInt (up to 5 bytes, the way packet bodies use it).  `Ok(None)` = incomplete.
pub fn read_varint(b: &[u8]) -> Result<Option<(u32, usize)>, FrameError> {
    let mut v = 0u32;
    for i in 0..5 {
        if i >= b.len() {
            return Ok(None);
        }
        let c = b[i];
        if i == 4 && c > 0x0f {
            return Err(FrameError::TooLong);
        }
        v |= ((c & 0x7f) as u32) << (7 * i);
        if c & 0x80 == 0 {
            return Ok(Some((v, i + 1)));
        }
    }
    Err(FrameError::TooLong)
}

pub fn write_varint(mut v: u32, out: &mut Vec<u8>) {
    loop {
        let b = (v & 0x7f) as u8;
        v >>= 7;
        if v == 0 {
            out.push(b);
            return;
        }
        out.push(b | 0x80);
    }
}

/// Accumulates bytes and cuts them into frames.  Memory is bounded: the owner must stop feeding when `buffered()` exceeds one frame of the
/// current limit plus one read; `next` rejects a length above `max_frame` as soon as its prefix is complete.
#[derive(Default)]
pub struct FrameSplitter {
    buf: BytesMut,
}

impl FrameSplitter {
    pub fn new() -> Self {
        Self { buf: BytesMut::new() }
    }
    pub fn push(&mut self, data: &[u8]) {
        self.buf.extend_from_slice(data);
    }
    pub fn buffered(&self) -> usize {
        self.buf.len()
    }
    /// The bytes not yet cut into frames.  Used once, when encryption starts in the middle of a read: those bytes are ciphertext.
    pub fn buffer_mut(&mut self) -> &mut [u8] {
        &mut self.buf[..]
    }
    /// The next whole frame (without its length prefix), `None` if more bytes are needed.
    pub fn next(&mut self, max_frame: usize) -> Result<Option<Bytes>, FrameError> {
        let (len, p) = match read_len_varint(&self.buf)? {
            Some(x) => x,
            None => return Ok(None),
        };
        if len == 0 {
            return Err(FrameError::ZeroLength);
        }
        if len > max_frame {
            return Err(FrameError::TooLarge(len));
        }
        if self.buf.len() < p + len {
            return Ok(None);
        }
        let _ = self.buf.split_to(p);
        Ok(Some(self.buf.split_to(len).freeze()))
    }
}

/// Inflates one frame of a connection that has compression on: `[VarInt data length][zlib data, or the raw packet when the length is 0]`
/// (vanilla's CompressionDecoder: a data length below the threshold or above 8,388,608 is an error, and the inflated size must match).
pub fn inflate_frame(frame: &Bytes, threshold: usize) -> Result<Bytes, FrameError> {
    let (dl, p) = match read_varint(frame) {
        Ok(Some(x)) => x,
        _ => return Err(FrameError::Compression("data length")),
    };
    let rest = &frame[p..];
    if dl == 0 {
        if rest.is_empty() {
            return Err(FrameError::Compression("empty packet"));
        }
        return Ok(frame.slice(p..));
    }
    let dl = dl as usize;
    if dl < threshold {
        return Err(FrameError::Compression("below the threshold"));
    }
    if dl > MAX_INFLATED {
        return Err(FrameError::Compression("inflated size too large"));
    }
    let mut out = Vec::with_capacity(dl.min(65536));
    let mut dec = flate2::read::ZlibDecoder::new(rest).take(dl as u64 + 1);
    dec.read_to_end(&mut out).map_err(|_| FrameError::Compression("corrupt data"))?;
    if out.len() != dl {
        return Err(FrameError::Compression("inflated size mismatch"));
    }
    Ok(Bytes::from(out))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(body: &[u8]) -> Vec<u8> {
        let mut v = Vec::new();
        write_varint(body.len() as u32, &mut v);
        v.extend_from_slice(body);
        v
    }

    #[test]
    fn splits_whole_frames() {
        let mut s = FrameSplitter::new();
        let mut data = frame(&[0, 1, 2]);
        data.extend(frame(&[7]));
        s.push(&data);
        assert_eq!(s.next(MAX_FRAME).unwrap().unwrap().as_ref(), &[0, 1, 2]);
        assert_eq!(s.next(MAX_FRAME).unwrap().unwrap().as_ref(), &[7]);
        assert_eq!(s.next(MAX_FRAME).unwrap(), None);
        assert_eq!(s.buffered(), 0);
    }

    #[test]
    fn incomplete_consumes_nothing() {
        let mut s = FrameSplitter::new();
        s.push(&[5, 1, 2]);
        assert_eq!(s.next(MAX_FRAME).unwrap(), None);
        assert_eq!(s.buffered(), 3);
        s.push(&[3, 4, 5]);
        assert_eq!(s.next(MAX_FRAME).unwrap().unwrap().as_ref(), &[1, 2, 3, 4, 5]);
    }

    #[test]
    fn zero_length_rejected() {
        let mut s = FrameSplitter::new();
        s.push(&[0]);
        assert_eq!(s.next(MAX_FRAME), Err(FrameError::ZeroLength));
    }

    #[test]
    fn overlong_rejected() {
        // 0x80 0x00 is a 2-byte encoding of 0; 0x81 0x00 of 1
        let mut s = FrameSplitter::new();
        s.push(&[0x81, 0x00, 1]);
        assert_eq!(s.next(MAX_FRAME), Err(FrameError::Overlong));
    }

    #[test]
    fn four_byte_length_rejected() {
        let mut s = FrameSplitter::new();
        s.push(&[0x80, 0x80, 0x80, 0x01]);
        assert_eq!(s.next(MAX_FRAME), Err(FrameError::TooLong));
    }

    #[test]
    fn largest_length_is_accepted_only_up_to_the_limit() {
        let mut s = FrameSplitter::new();
        s.push(&[0xff, 0xff, 0x7f]); // 2,097,151
        assert_eq!(s.next(MAX_FRAME).unwrap(), None); // valid, waiting for the body
        let mut s2 = FrameSplitter::new();
        s2.push(&[0xff, 0xff, 0x7f]);
        assert_eq!(s2.next(1024), Err(FrameError::TooLarge(2_097_151))); // above this connection's limit: rejected, not waited for
    }

    #[test]
    fn a_length_split_across_reads() {
        let mut s = FrameSplitter::new();
        s.push(&[0x80]);
        assert_eq!(s.next(MAX_FRAME).unwrap(), None);
        s.push(&[0x01]); // 128
        assert_eq!(s.buffered(), 2);
        s.push(&vec![9u8; 128]);
        assert_eq!(s.next(MAX_FRAME).unwrap().unwrap().len(), 128);
    }

    #[test]
    fn inflate_raw_and_zlib() {
        use flate2::{write::ZlibEncoder, Compression};
        use std::io::Write;
        // data length 0: raw
        let mut raw = vec![0u8];
        raw.extend_from_slice(&[1, 2, 3]);
        assert_eq!(inflate_frame(&Bytes::from(raw), 256).unwrap().as_ref(), &[1, 2, 3]);
        // compressed
        let payload = vec![42u8; 1000];
        let mut e = ZlibEncoder::new(Vec::new(), Compression::default());
        e.write_all(&payload).unwrap();
        let z = e.finish().unwrap();
        let mut f = Vec::new();
        write_varint(1000, &mut f);
        f.extend_from_slice(&z);
        assert_eq!(inflate_frame(&Bytes::from(f.clone()), 256).unwrap().as_ref(), &payload[..]);
        // below the threshold is an error
        assert!(inflate_frame(&Bytes::from(f.clone()), 2000).is_err());
        // wrong announced size
        let mut bad = Vec::new();
        write_varint(999, &mut bad);
        bad.extend_from_slice(&z);
        assert!(inflate_frame(&Bytes::from(bad), 256).is_err());
        // corrupt
        let mut c = Vec::new();
        write_varint(1000, &mut c);
        c.extend_from_slice(&[1, 2, 3, 4]);
        assert!(inflate_frame(&Bytes::from(c), 256).is_err());
    }

    #[test]
    fn inflate_bomb_is_bounded() {
        use flate2::{write::ZlibEncoder, Compression};
        use std::io::Write;
        // announces 300 bytes but the stream inflates to 10 MB: must stop at 301 bytes and fail
        let mut e = ZlibEncoder::new(Vec::new(), Compression::best());
        e.write_all(&vec![0u8; 10_000_000]).unwrap();
        let z = e.finish().unwrap();
        let mut f = Vec::new();
        write_varint(300, &mut f);
        f.extend_from_slice(&z);
        assert!(inflate_frame(&Bytes::from(f), 256).is_err());
    }
}
