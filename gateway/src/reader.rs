//! The inbound half of one connection, as a pure state machine (no sockets): bytes in, frames out.
//! It decrypts (once online-mode encryption has started), cuts frames with adacraft's rules, inflates them when the connection's compression is on, and recognises the ONE
//! frame the gateway interprets: the answer to an encryption request.  The database tells it about compression, the play state and a pending key request through
//! `control` (the rows of net.gateway_ctl).

use dbcraft_gateway_core::frame::{inflate_frame, FrameSplitter, MAX_FRAME};

/// A stream cipher applied in place (AES-128-CFB8 decryption in production; the verified std-only cipher in tests).
pub trait StreamCipher {
    fn apply(&mut self, data: &mut [u8]);
}

impl StreamCipher for crate::ffi::ossl::Cfb8Stream {
    fn apply(&mut self, data: &mut [u8]) {
        crate::ffi::ossl::Cfb8Stream::apply(self, data)
    }
}

/// The reference cipher used as a decryptor (tests).
#[cfg(test)]
pub struct RefDecrypt(pub dbcraft_gateway_core::aes::Cfb8);
#[cfg(test)]
impl StreamCipher for RefDecrypt {
    fn apply(&mut self, data: &mut [u8]) {
        self.0.decrypt(data)
    }
}

/// A pending encryption request: the next complete frame answers it.
#[derive(Debug, Clone, PartialEq)]
pub struct Await {
    pub token: Vec<u8>,
    pub name: String,
}

#[derive(Debug, Clone, Copy)]
pub struct ReaderLimits {
    pub prelogin_max_frame: usize,
    pub prelogin_max_bytes: usize,
}

#[derive(Debug, PartialEq)]
pub enum Item {
    /// a frame (without its length prefix), inflated if the connection's compression is on: goes to net.inbox
    Frame(Vec<u8>),
    /// the frame that answers the encryption request: NOT passed to the database
    Key(Vec<u8>),
}

#[derive(Debug, PartialEq)]
pub struct ReadError(pub String);

pub struct Reader {
    split: FrameSplitter,
    thr: i32,
    play: bool,
    awaiting: Option<Await>,
    dec: Option<Box<dyn StreamCipher + Send>>,
    prelogin_bytes: usize,
    limits: ReaderLimits,
}

impl Reader {
    pub fn new(limits: ReaderLimits) -> Reader {
        Reader { split: FrameSplitter::new(), thr: -1, play: false, awaiting: None, dec: None, prelogin_bytes: 0, limits }
    }

    /// The database's control row for this connection.
    pub fn control(&mut self, compression: Option<i32>, state: &str, await_key: Option<Await>) {
        self.thr = compression.unwrap_or(-1);
        self.play = state == "play";
        if let Some(a) = await_key {
            self.awaiting = Some(a);
        }
    }

    pub fn awaiting(&self) -> Option<&Await> {
        self.awaiting.as_ref()
    }
    #[cfg(test)]
    pub fn encrypted(&self) -> bool {
        self.dec.is_some()
    }
    pub fn buffered(&self) -> usize {
        self.split.buffered()
    }

    /// New bytes from the socket (decrypted in place when encryption is on).
    pub fn feed(&mut self, data: &mut [u8]) -> Result<(), ReadError> {
        if let Some(d) = self.dec.as_mut() {
            d.apply(data);
        }
        if !self.play {
            self.prelogin_bytes = self.prelogin_bytes.saturating_add(data.len());
            if self.prelogin_bytes > self.limits.prelogin_max_bytes {
                return Err(ReadError("pre-login byte budget exceeded".into()));
            }
        }
        self.split.push(data);
        Ok(())
    }

    /// The next item, `None` when more bytes are needed.  After an `Item::Key` the caller must answer with `accept_key` (or drop the connection).
    pub fn next_item(&mut self) -> Result<Option<Item>, ReadError> {
        let max = if self.play { MAX_FRAME } else { self.limits.prelogin_max_frame.min(MAX_FRAME) };
        let frame = match self.split.next(max) {
            Ok(Some(f)) => f,
            Ok(None) => return Ok(None),
            Err(e) => return Err(ReadError(e.to_string())),
        };
        if self.awaiting.is_some() {
            return Ok(Some(Item::Key(frame)));
        }
        if self.thr >= 0 {
            return match inflate_frame(&frame, self.thr as usize) {
                Ok(p) => Ok(Some(Item::Frame(p))),
                Err(e) => Err(ReadError(e.to_string())),
            };
        }
        Ok(Some(Item::Frame(frame)))
    }

    /// The key response was valid: everything after it on the wire is ciphertext, including bytes already buffered behind the key frame.
    pub fn accept_key(&mut self, mut dec: Box<dyn StreamCipher + Send>) {
        self.awaiting = None;
        dec.apply(self.split.buffer_mut());
        self.dec = Some(dec);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use dbcraft_gateway_core::aes::Cfb8;
    use dbcraft_gateway_core::frame::write_varint;
    use dbcraft_gateway_core::inflate::adler32;

    fn limits() -> ReaderLimits {
        ReaderLimits { prelogin_max_frame: 1000, prelogin_max_bytes: 5000 }
    }
    fn frame(payload: &[u8]) -> Vec<u8> {
        let mut v = Vec::new();
        write_varint(payload.len() as u32, &mut v);
        v.extend_from_slice(payload);
        v
    }
    fn rnd(s: &mut u64) -> u64 {
        *s = s.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        *s >> 33
    }
    fn drain(r: &mut Reader) -> Result<Vec<Item>, ReadError> {
        let mut v = Vec::new();
        while let Some(i) = r.next_item()? {
            v.push(i);
        }
        Ok(v)
    }
    /// a zlib stream made of one stored deflate block (valid for any inflater)
    fn zlib_stored(data: &[u8]) -> Vec<u8> {
        let mut z = vec![0x78, 0x01, 0x01];
        z.extend_from_slice(&(data.len() as u16).to_le_bytes());
        z.extend_from_slice(&(!(data.len() as u16)).to_le_bytes());
        z.extend_from_slice(data);
        z.extend_from_slice(&adler32(data).to_be_bytes());
        z
    }

    #[test]
    fn frames_survive_any_cutting_of_the_byte_stream() {
        let mut s = 1u64;
        let payloads: Vec<Vec<u8>> = (0..200).map(|i| (0..1 + (rnd(&mut s) as usize % 300)).map(|j| (i * 7 + j) as u8).collect()).collect();
        let stream: Vec<u8> = payloads.iter().flat_map(|p| frame(p)).collect();
        for _ in 0..30 {
            let mut r = Reader::new(ReaderLimits { prelogin_max_frame: 1000, prelogin_max_bytes: usize::MAX });
            let mut got = Vec::new();
            let mut i = 0;
            while i < stream.len() {
                let n = 1 + rnd(&mut s) as usize % 97;
                let end = (i + n).min(stream.len());
                let mut chunk = stream[i..end].to_vec();
                r.feed(&mut chunk).unwrap();
                for it in drain(&mut r).unwrap() {
                    match it {
                        Item::Frame(p) => got.push(p),
                        Item::Key(_) => panic!("no key was awaited"),
                    }
                }
                i = end;
            }
            assert_eq!(got, payloads);
        }
    }

    #[test]
    fn framing_violations_are_errors() {
        // length 0
        let mut r = Reader::new(limits());
        r.feed(&mut [0u8]).unwrap();
        assert!(r.next_item().is_err());
        // overlong length encoding (0x80 0x00)
        let mut r = Reader::new(limits());
        r.feed(&mut [0x80, 0x00]).unwrap();
        assert!(r.next_item().is_err());
        // a 4-byte length VarInt
        let mut r = Reader::new(limits());
        r.feed(&mut [0x80, 0x80, 0x80, 0x01]).unwrap();
        assert!(r.next_item().is_err());
        // longer than the pre-login limit: rejected from the prefix alone, without waiting for the bytes
        let mut r = Reader::new(limits());
        let mut p = Vec::new();
        write_varint(1001, &mut p);
        r.feed(&mut p).unwrap();
        assert!(r.next_item().is_err());
    }

    #[test]
    fn the_play_state_lifts_the_small_frame_limit() {
        let big = vec![7u8; 5000];
        let mut r = Reader::new(ReaderLimits { prelogin_max_frame: 1000, prelogin_max_bytes: usize::MAX });
        r.feed(&mut frame(&big)).unwrap();
        assert!(r.next_item().is_err(), "5000 bytes before play");
        let mut r = Reader::new(ReaderLimits { prelogin_max_frame: 1000, prelogin_max_bytes: usize::MAX });
        r.control(Some(-1), "play", None);
        r.feed(&mut frame(&big)).unwrap();
        assert_eq!(r.next_item().unwrap(), Some(Item::Frame(big)));
    }

    #[test]
    fn the_prelogin_byte_budget_stops_a_flood_but_not_play() {
        let mut r = Reader::new(limits());
        for _ in 0..4 {
            r.feed(&mut vec![0u8; 1000]).unwrap();
            let _ = r.next_item();
        }
        assert!(r.feed(&mut vec![0u8; 1001]).is_err());
        let mut r = Reader::new(limits());
        r.control(None, "play", None);
        for _ in 0..100 {
            r.feed(&mut frame(&[1u8; 100])).unwrap();
            while r.next_item().unwrap().is_some() {}
        }
    }

    #[test]
    fn compression_data_length_zero_is_raw_and_otherwise_inflated() {
        let mut r = Reader::new(limits());
        r.control(Some(256), "play", None);
        // below the threshold: data length 0 then the raw packet
        let mut f = vec![0u8];
        f.extend_from_slice(b"hello");
        r.feed(&mut frame(&f)).unwrap();
        assert_eq!(r.next_item().unwrap(), Some(Item::Frame(b"hello".to_vec())));
        // at or above the threshold: data length = inflated size, then zlib
        let data = vec![42u8; 300];
        let mut f = Vec::new();
        write_varint(300, &mut f);
        f.extend_from_slice(&zlib_stored(&data));
        r.feed(&mut frame(&f)).unwrap();
        assert_eq!(r.next_item().unwrap(), Some(Item::Frame(data)));
    }

    #[test]
    fn bad_compressed_frames_are_errors() {
        let data = vec![1u8; 300];
        // data length below the threshold
        let mut r = Reader::new(limits());
        r.control(Some(256), "play", None);
        let mut f = Vec::new();
        write_varint(100, &mut f);
        f.extend_from_slice(&zlib_stored(&data[..100]));
        r.feed(&mut frame(&f)).unwrap();
        assert!(r.next_item().is_err());
        // announced size does not match the inflated size
        let mut r = Reader::new(limits());
        r.control(Some(256), "play", None);
        let mut f = Vec::new();
        write_varint(400, &mut f);
        f.extend_from_slice(&zlib_stored(&data));
        r.feed(&mut frame(&f)).unwrap();
        assert!(r.next_item().is_err());
        // announced size above vanilla's limit
        let mut r = Reader::new(limits());
        r.control(Some(256), "play", None);
        let mut f = Vec::new();
        write_varint(8_388_609, &mut f);
        f.extend_from_slice(&zlib_stored(&data));
        r.feed(&mut frame(&f)).unwrap();
        assert!(r.next_item().is_err());
        // garbage instead of zlib
        let mut r = Reader::new(limits());
        r.control(Some(256), "play", None);
        let mut f = Vec::new();
        write_varint(300, &mut f);
        f.extend_from_slice(&[0xde, 0xad, 0xbe, 0xef, 1, 2, 3]);
        r.feed(&mut frame(&f)).unwrap();
        assert!(r.next_item().is_err());
        // data length 0 with nothing behind it
        let mut r = Reader::new(limits());
        r.control(Some(256), "play", None);
        r.feed(&mut frame(&[0u8])).unwrap();
        assert!(r.next_item().is_err());
    }

    #[test]
    fn the_key_frame_is_returned_apart_and_the_bytes_behind_it_are_decrypted() {
        let secret = [0x42u8; 16];
        let mut r = Reader::new(limits());
        r.control(Some(-1), "login", Some(Await { token: vec![1, 2, 3, 4], name: "Probe".into() }));
        assert_eq!(r.awaiting().unwrap().name, "Probe");
        // the client sends the key frame in plaintext, then encrypts everything that follows
        let key_frame = frame(&[0x01, 0xaa, 0xbb]);
        let later1 = frame(b"first packet after the key");
        let later2 = frame(b"second");
        let mut client = Cfb8::new(&secret);
        let mut enc = [later1.clone(), later2.clone()].concat();
        client.encrypt(&mut enc);
        // everything arrives in ONE read
        let mut wire = key_frame.clone();
        wire.extend_from_slice(&enc);
        r.feed(&mut wire).unwrap();
        match r.next_item().unwrap() {
            Some(Item::Key(k)) => assert_eq!(k, vec![0x01, 0xaa, 0xbb]),
            other => panic!("expected the key frame, got {other:?}"),
        }
        r.accept_key(Box::new(RefDecrypt(Cfb8::new(&secret))));
        assert!(r.encrypted() && r.awaiting().is_none());
        assert_eq!(r.next_item().unwrap(), Some(Item::Frame(b"first packet after the key".to_vec())));
        assert_eq!(r.next_item().unwrap(), Some(Item::Frame(b"second".to_vec())));
        assert_eq!(r.next_item().unwrap(), None);
        // and later reads are decrypted on the way in
        let mut more = frame(b"third");
        client.encrypt(&mut more);
        r.feed(&mut more).unwrap();
        assert_eq!(r.next_item().unwrap(), Some(Item::Frame(b"third".to_vec())));
    }

    #[test]
    fn nothing_but_the_awaited_frame_is_treated_as_the_key() {
        let mut r = Reader::new(limits());
        r.feed(&mut frame(b"abc")).unwrap();
        assert_eq!(r.next_item().unwrap(), Some(Item::Frame(b"abc".to_vec())), "without a pending request every frame goes to the database");
    }

    #[test]
    fn random_streams_never_panic_and_memory_stays_bounded() {
        let mut s = 99u64;
        for _ in 0..300 {
            let mut r = Reader::new(ReaderLimits { prelogin_max_frame: 2000, prelogin_max_bytes: 100_000 });
            if rnd(&mut s) % 2 == 0 {
                r.control(Some((rnd(&mut s) % 400) as i32 - 1), if rnd(&mut s) % 2 == 0 { "play" } else { "login" }, None);
            }
            for _ in 0..40 {
                let n = rnd(&mut s) as usize % 400;
                let mut chunk: Vec<u8> = (0..n).map(|_| (rnd(&mut s) % 256) as u8).collect();
                if r.feed(&mut chunk).is_err() {
                    break;
                }
                loop {
                    match r.next_item() {
                        Ok(Some(_)) => {}
                        Ok(None) => break,
                        Err(_) => break,
                    }
                }
                assert!(r.buffered() <= 2_097_151 + 400 + 3, "buffered {}", r.buffered());
            }
        }
    }
}
