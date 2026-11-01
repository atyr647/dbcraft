//! Real zlib streams (tests/gen_inflate_vectors.py, Python's zlib: stored, fixed and dynamic Huffman blocks, RLE and Huffman-only strategies, streams
//! of several blocks) must inflate to the data the same formulas regenerate here.

use dbcraft_gateway_core::inflate::zlib_decompress;

const WORDS: [&[u8]; 9] = [b"minecraft", b"stone", b"dirt", b"grass_block", b"level_chunk", b"player", b"chat", b" ", b"\n"];

fn plain(kind: &str, n: usize, seed: u32) -> Vec<u8> {
    match kind {
        "lcg" => {
            let mut x = seed;
            (0..n)
                .map(|_| {
                    x = x.wrapping_mul(1103515245).wrapping_add(12345) & 0x7fff_ffff;
                    ((x >> 16) & 0xff) as u8
                })
                .collect()
        }
        "runs" => (0..n).map(|i| (((i / 37) * 5) & 0xff) as u8).collect(),
        "text" => {
            let mut x = seed;
            let mut out = Vec::with_capacity(n + 16);
            while out.len() < n {
                x = x.wrapping_mul(1103515245).wrapping_add(12345) & 0x7fff_ffff;
                out.extend_from_slice(WORDS[((x >> 16) as usize) % WORDS.len()]);
            }
            out.truncate(n);
            out
        }
        _ => panic!("unknown kind {kind}"),
    }
}

fn unhex(s: &str) -> Vec<u8> {
    (0..s.len() / 2).map(|i| u8::from_str_radix(&s[2 * i..2 * i + 2], 16).unwrap()).collect()
}

#[test]
fn zlib_made_streams_inflate_to_the_original() {
    let text = include_str!("inflate_vectors.txt");
    let mut checked = 0;
    for line in text.lines() {
        let p: Vec<&str> = line.split(' ').collect();
        let (kind, n, seed) = (p[0], p[1].parse::<usize>().unwrap(), p[2].parse::<u32>().unwrap());
        let expect = plain(kind, n, seed);
        let got = zlib_decompress(&unhex(p[5]), n).unwrap_or_else(|e| panic!("{kind} n={n} level={} {}: {e}", p[3], p[4]));
        assert!(got == expect, "{kind} n={n} level={} strategy={}: output differs", p[3], p[4]);
        // one byte less of limit must fail (the limit is enforced), unless the output is empty
        if n > 0 {
            assert!(zlib_decompress(&unhex(p[5]), n - 1).is_err(), "limit n-1 accepted for {kind} n={n}");
        }
        checked += 1;
    }
    assert!(checked > 200, "only {checked} vectors");
}

#[test]
fn every_truncation_of_a_real_stream_fails_cleanly() {
    let text = include_str!("inflate_vectors.txt");
    let line = text.lines().find(|l| l.starts_with("text 5000 42 6 default")).unwrap();
    let z = unhex(line.split(' ').nth(5).unwrap());
    for cut in 0..z.len() {
        assert!(zlib_decompress(&z[..cut], 1 << 20).is_err(), "truncation at {cut} accepted");
    }
}

#[test]
fn single_bit_flips_never_panic() {
    let text = include_str!("inflate_vectors.txt");
    let line = text.lines().find(|l| l.starts_with("text 5000 42 9 default")).unwrap();
    let z = unhex(line.split(' ').nth(5).unwrap());
    for i in 0..z.len() {
        for bit in 0..8 {
            let mut m = z.clone();
            m[i] ^= 1 << bit;
            let _ = zlib_decompress(&m, 1 << 20); // may succeed on a flipped padding bit, must not panic or hang
        }
    }
}
