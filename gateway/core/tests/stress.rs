//! Randomised stress test of the splitter and the inflater on hostile input (no crates: a fixed-seed generator).
//!   * arbitrary bytes, cut arbitrarily, never panic;
//!   * after an error the owner closes the connection, and until then the buffer never exceeds one frame of the current limit plus one read;
//!   * a stream of valid frames, cut at random places (including byte by byte), yields the same frames in the same order.

use dbcraft_gateway_core::frame::{inflate_frame, write_varint, FrameSplitter, MAX_FRAME};

struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }
}

#[test]
fn arbitrary_bytes_never_panic_and_memory_stays_bounded() {
    let mut r = Rng(0x9e3779b97f4a7c15);
    for round in 0..3000 {
        let max_frame = [64usize, 1024, 8192, MAX_FRAME][round % 4];
        let read = 1 + r.below(2000);
        let mut s = FrameSplitter::new();
        for _ in 0..40 {
            let n = 1 + r.below(read);
            let mut chunk = vec![0u8; n];
            for b in chunk.iter_mut() {
                // bias toward VarInt-looking bytes so lengths of every size occur
                *b = match r.below(4) {
                    0 => 0x80 | (r.below(128) as u8),
                    1 => r.below(128) as u8,
                    _ => r.next() as u8,
                };
            }
            s.push(&chunk);
            let mut failed = false;
            loop {
                match s.next(max_frame) {
                    Ok(Some(f)) => assert!(!f.is_empty() && f.len() <= max_frame),
                    Ok(None) => break,
                    Err(_) => {
                        failed = true;
                        break;
                    }
                }
            }
            assert!(s.buffered() <= max_frame + 3 + read, "buffer {} over bound (limit {max_frame}, read {read})", s.buffered());
            if failed {
                break; // the gateway closes the connection here
            }
        }
    }
}

#[test]
fn valid_streams_cut_anywhere_give_the_same_frames() {
    let mut r = Rng(12345);
    for _ in 0..500 {
        let mut frames: Vec<Vec<u8>> = Vec::new();
        let mut wire = Vec::new();
        for _ in 0..(1 + r.below(30)) {
            let len = [1usize, 2, 5, 127, 128, 129, 300, 16383, 16384, 20000][r.below(10)];
            let f: Vec<u8> = (0..len).map(|_| r.next() as u8).collect();
            write_varint(len as u32, &mut wire);
            wire.extend_from_slice(&f);
            frames.push(f);
        }
        let mut s = FrameSplitter::new();
        let mut got: Vec<Vec<u8>> = Vec::new();
        let mut o = 0;
        while o < wire.len() {
            let n = if r.below(3) == 0 { 1 } else { 1 + r.below(5000) };
            let end = (o + n).min(wire.len());
            s.push(&wire[o..end]);
            o = end;
            while let Some(f) = s.next(MAX_FRAME).unwrap() {
                got.push(f);
            }
        }
        assert_eq!(got, frames);
        assert_eq!(s.buffered(), 0);
    }
}

#[test]
fn compressed_frame_garbage_never_panics() {
    let mut r = Rng(777);
    for _ in 0..5000 {
        let n = r.below(80);
        let f: Vec<u8> = (0..n).map(|_| r.next() as u8).collect();
        let _ = inflate_frame(&f, 256);
        // a plausible header with a random body
        let mut g = Vec::new();
        write_varint(256 + r.below(100_000) as u32, &mut g);
        g.extend((0..r.below(200)).map(|_| r.next() as u8));
        let _ = inflate_frame(&g, 256);
    }
}
