//! Frame splitting and inbound decompression, with adacraft's rules (adacraft/docs/PROTOCOL.md): the length is a VarInt of at most 3 bytes (value at
//! most 2,097,151); an overlong encoding (a multi-byte value whose last group is 0) is rejected; a length of 0 is rejected; a length above the
//! connection's limit is rejected instead of waited for.  An incomplete frame returns `None` and consumes nothing.
//! The gateway never parses packets: a frame is handed to the database as it is, minus its length prefix.

use crate::inflate;

/// Largest frame the length field can express (3-byte VarInt).
pub const MAX_FRAME: usize = 2_097_151;
/// Vanilla's limit for a decompressed packet.
pub const MAX_INFLATED: usize = 8_388_608;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FrameError {
    Overlong,
    TooLong,
    ZeroLength,
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

/// Reads a frame-length VarInt.  `Ok(None)` = the buffer ends inside it.  Returns (value, bytes used).
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

/// General VarInt (up to 5 bytes, as packet bodies use it).  `Ok(None)` = incomplete.
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

/// Accumulates bytes and cuts them into frames.  Memory is bounded when the owner stops feeding while `buffered()` exceeds one frame of the
/// current limit plus one read: `next` rejects a length above the limit as soon as its prefix is complete.
#[derive(Default)]
pub struct FrameSplitter {
    buf: Vec<u8>,
    head: usize,
}

impl FrameSplitter {
    pub fn new() -> Self {
        Self { buf: Vec::new(), head: 0 }
    }
    pub fn push(&mut self, data: &[u8]) {
        if self.head > 0 && self.head >= self.buf.len() / 2 {
            self.buf.drain(..self.head);
            self.head = 0;
        }
        self.buf.extend_from_slice(data);
    }
    pub fn buffered(&self) -> usize {
        self.buf.len() - self.head
    }
    /// The bytes not yet cut into frames (ciphertext when encryption starts in the middle of a read).
    pub fn buffer_mut(&mut self) -> &mut [u8] {
        &mut self.buf[self.head..]
    }
    /// The next whole frame (without its length prefix), `None` if more bytes are needed.
    pub fn next(&mut self, max_frame: usize) -> Result<Option<Vec<u8>>, FrameError> {
        let (len, p) = match read_len_varint(&self.buf[self.head..])? {
            Some(x) => x,
            None => return Ok(None),
        };
        if len == 0 {
            return Err(FrameError::ZeroLength);
        }
        if len > max_frame {
            return Err(FrameError::TooLarge(len));
        }
        if self.buffered() < p + len {
            return Ok(None);
        }
        let start = self.head + p;
        let frame = self.buf[start..start + len].to_vec();
        self.head = start + len;
        if self.head == self.buf.len() {
            self.buf.clear();
            self.head = 0;
        }
        Ok(Some(frame))
    }
}

/// Inflates one frame of a connection that has compression on: `[VarInt data length][zlib data, or the raw packet when the length is 0]`
/// (vanilla's CompressionDecoder: a data length below the threshold or above 8,388,608 is an error, and the inflated size must match).
pub fn inflate_frame(frame: &[u8], threshold: usize) -> Result<Vec<u8>, FrameError> {
    let (dl, p) = match read_varint(frame) {
        Ok(Some(x)) => x,
        _ => return Err(FrameError::Compression("data length")),
    };
    let rest = &frame[p..];
    if dl == 0 {
        if rest.is_empty() {
            return Err(FrameError::Compression("empty packet"));
        }
        return Ok(rest.to_vec());
    }
    let dl = dl as usize;
    if dl < threshold {
        return Err(FrameError::Compression("below the threshold"));
    }
    if dl > MAX_INFLATED {
        return Err(FrameError::Compression("inflated size too large"));
    }
    let out = inflate::zlib_decompress(rest, dl).map_err(FrameError::Compression)?;
    if out.len() != dl {
        return Err(FrameError::Compression("inflated size mismatch"));
    }
    Ok(out)
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
        assert_eq!(s.next(MAX_FRAME).unwrap().unwrap(), vec![0, 1, 2]);
        assert_eq!(s.next(MAX_FRAME).unwrap().unwrap(), vec![7]);
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
        assert_eq!(s.next(MAX_FRAME).unwrap().unwrap(), vec![1, 2, 3, 4, 5]);
    }

    #[test]
    fn zero_length_rejected() {
        let mut s = FrameSplitter::new();
        s.push(&[0]);
        assert_eq!(s.next(MAX_FRAME), Err(FrameError::ZeroLength));
    }

    #[test]
    fn overlong_rejected() {
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
    fn largest_length_waits_only_up_to_the_limit() {
        let mut s = FrameSplitter::new();
        s.push(&[0xff, 0xff, 0x7f]); // 2,097,151
        assert_eq!(s.next(MAX_FRAME).unwrap(), None);
        let mut s2 = FrameSplitter::new();
        s2.push(&[0xff, 0xff, 0x7f]);
        assert_eq!(s2.next(1024), Err(FrameError::TooLarge(2_097_151)));
    }

    #[test]
    fn a_length_split_across_reads() {
        let mut s = FrameSplitter::new();
        s.push(&[0x80]);
        assert_eq!(s.next(MAX_FRAME).unwrap(), None);
        s.push(&[0x01]);
        s.push(&vec![9u8; 128]);
        assert_eq!(s.next(MAX_FRAME).unwrap().unwrap().len(), 128);
    }

    #[test]
    fn byte_at_a_time_gives_the_same_frames() {
        let mut data = Vec::new();
        for n in [1usize, 5, 127, 128, 300, 1] {
            data.extend(frame(&vec![n as u8; n]));
        }
        let mut s = FrameSplitter::new();
        let mut got = Vec::new();
        for b in &data {
            s.push(&[*b]);
            while let Some(f) = s.next(MAX_FRAME).unwrap() {
                got.push(f.len());
            }
        }
        assert_eq!(got, vec![1, 5, 127, 128, 300, 1]);
    }

    #[test]
    fn inflate_raw_zlib_and_errors() {
        // data length 0: the rest is the raw packet
        assert_eq!(inflate_frame(&[0, 1, 2, 3], 256).unwrap(), vec![1, 2, 3]);
        assert!(inflate_frame(&[0], 256).is_err());
        // a zlib stream of 300 times 'a' made with Python's zlib (level 6)
        let z = [0x78u8, 0x9c, 0x4b, 0x4c, 0x1c, 0x05, 0xc4, 0x02, 0x00, 0xd8, 0xa8, 0x71, 0xad];
        let mut f = Vec::new();
        write_varint(300, &mut f);
        f.extend_from_slice(&z);
        assert_eq!(inflate_frame(&f, 256).unwrap(), vec![b'a'; 300]);
        assert!(inflate_frame(&f, 400).is_err()); // below the threshold
        let mut wrong = Vec::new();
        write_varint(299, &mut wrong);
        wrong.extend_from_slice(&z);
        assert!(inflate_frame(&wrong, 256).is_err()); // announced size does not match
    }
}
