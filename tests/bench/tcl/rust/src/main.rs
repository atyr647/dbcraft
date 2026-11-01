// Rust baseline for the Tcl gateway hot-path benchmarks.  std only; zlib through FFI to the same libz Tcl uses.
// Same inputs (data/), same logic, same RESULT lines as run.tcl.
use std::fs;
use std::hint::black_box;
use std::os::raw::{c_int, c_ulong};
use std::time::Instant;

#[link(name = "z")]
extern "C" {
    fn compress2(dest: *mut u8, dest_len: *mut c_ulong, src: *const u8, src_len: c_ulong, level: c_int) -> c_int;
    fn uncompress(dest: *mut u8, dest_len: *mut c_ulong, src: *const u8, src_len: c_ulong) -> c_int;
    fn compressBound(n: c_ulong) -> c_ulong;
}

fn bench<T>(name: &str, units: u64, bytes: u64, reps: u32, mut f: impl FnMut() -> T) -> T {
    let mut best = f64::MAX;
    let mut last = None;
    for _ in 0..reps {
        let t0 = Instant::now();
        let r = f();
        let t = t0.elapsed().as_secs_f64();
        if t < best { best = t; }
        last = Some(r);
    }
    println!("BENCH {} {:.9} {} {}", name, best, units, bytes);
    last.unwrap()
}

// ---- (a) VarInt
fn vi_decode_all(buf: &[u8]) -> (u64, u64) {
    let (mut i, mut sum, mut count) = (0usize, 0u64, 0u64);
    while i < buf.len() {
        let (mut v, mut shift) = (0u64, 0u32);
        loop {
            let b = buf[i];
            i += 1;
            v |= ((b & 0x7f) as u64) << shift;
            if b & 0x80 == 0 { break; }
            shift += 7;
        }
        sum += v;
        count += 1;
    }
    (count, sum)
}

fn vi_encode_all(vals: &[u32]) -> Vec<u8> {
    let mut out = Vec::with_capacity(vals.len() * 2);
    for &v in vals {
        let mut v = v;
        while v >= 0x80 {
            out.push(((v & 0x7f) | 0x80) as u8);
            v >>= 7;
        }
        out.push(v as u8);
    }
    out
}

// ---- (b) frame splitting (the Tcl "scan" and "index" variants are the same loop natively)
fn read_vi(buf: &[u8], pos: &mut usize) -> u64 {
    let (mut v, mut shift) = (0u64, 0u32);
    loop {
        let b = buf[*pos];
        *pos += 1;
        v |= ((b & 0x7f) as u64) << shift;
        if b & 0x80 == 0 { return v; }
        shift += 7;
    }
}

fn split_frames(buf: &[u8]) -> (u64, u64, u64) {
    let (mut pos, mut frames, mut idsum, mut bodybytes) = (0usize, 0u64, 0u64, 0u64);
    while pos < buf.len() {
        let len = read_vi(buf, &mut pos) as usize;
        let end = pos + len;
        let id = read_vi(buf, &mut pos);
        idsum += id;
        let body = buf[pos..end].to_vec(); // copy the body out like the Tcl version does
        bodybytes += black_box(&body).len() as u64;
        pos = end;
        frames += 1;
    }
    (frames, idsum, bodybytes)
}

// ---- (c) position decode
fn pos_decode_loop(payloads: &[[u8; 33]], iters: usize) -> (f64, u64) {
    let (mut sx, mut sflags) = (0.0f64, 0u64);
    for i in 0..iters {
        let p = &payloads[i % payloads.len()];
        let x = f64::from_be_bytes(p[0..8].try_into().unwrap());
        let _y = f64::from_be_bytes(p[8..16].try_into().unwrap());
        let z = f64::from_be_bytes(p[16..24].try_into().unwrap());
        let yaw = f32::from_be_bytes(p[24..28].try_into().unwrap()) as f64;
        let pitch = f32::from_be_bytes(p[28..32].try_into().unwrap()) as f64;
        sx = sx + x + z + yaw + pitch;
        sflags += p[32] as u64;
    }
    (sx, sflags)
}

// ---- (d) build frames
fn vi_push(out: &mut Vec<u8>, mut n: u32) {
    while n >= 0x80 { out.push(((n & 0x7f) | 0x80) as u8); n >>= 7; }
    out.push(n as u8);
}

fn build_frames(iters: u32) -> Vec<u8> {
    let mut out = Vec::new();
    for i in 0..iters {
        let mut body = Vec::with_capacity(32);
        body.extend_from_slice(&i.to_be_bytes());
        body.extend_from_slice(&((i as f64) * 0.5).to_be_bytes());
        body.extend_from_slice(&64.0f64.to_be_bytes());
        body.extend_from_slice(&((i as f64) * 0.25).to_be_bytes());
        body.push((i & 255) as u8);
        body.push(((i >> 3) & 255) as u8);
        let mut id = Vec::with_capacity(2);
        vi_push(&mut id, 0x2f + (i & 3));
        vi_push(&mut out, (id.len() + body.len()) as u32);
        out.extend_from_slice(&id);
        out.extend_from_slice(&body);
    }
    out
}

// ---- (e) 2000 connection state machines (a plain enum state machine: no coroutines needed natively)
#[derive(Clone, Copy)]
struct Conn { state: u8, moves: u64, chats: u64, other: u64, bytes: u64 }

fn run_conns(nconn: usize, rounds: usize) -> (u64, u64, u64, u64) {
    let mut conns = vec![Conn { state: 0, moves: 0, chats: 0, other: 0, bytes: 0 }; nconn];
    let kinds = [28u32, 29, 6, 27];
    for r in 0..rounds {
        for c in 0..nconn {
            let id = if r < 3 { 0 } else { kinds[(c + r) & 3] };
            let len = 10 + ((c * 7 + r * 13) % 40);
            let cn = &mut conns[c];
            cn.bytes += len as u64;
            match cn.state {
                0 => cn.state = 1,
                1 => cn.state = 2,
                2 => cn.state = 3,
                _ => {
                    if id == 0x1c || id == 0x1d { cn.moves += 1 } else if id == 6 { cn.chats += 1 } else { cn.other += 1 }
                }
            }
        }
    }
    conns.iter().fold((0, 0, 0, 0), |a, c| (a.0 + c.moves, a.1 + c.chats, a.2 + c.other, a.3 + c.bytes))
}

// ---- (f) AES-128: software and AES-NI, CFB8 on top
const RCON: [u8; 10] = [1, 2, 4, 8, 16, 32, 64, 128, 0x1b, 0x36];
fn gmul(mut a: u8, mut b: u8) -> u8 {
    let mut p = 0u8;
    for _ in 0..8 {
        if b & 1 != 0 { p ^= a; }
        let hi = a & 0x80;
        a <<= 1;
        if hi != 0 { a ^= 0x1b; }
        b >>= 1;
    }
    p
}
fn make_sbox() -> [u8; 256] {
    let mut sbox = [0u8; 256];
    for x in 0..=255u8 {
        let inv = if x == 0 { 0 } else { (1..=255u8).find(|&y| gmul(x, y) == 1).unwrap() };
        let (mut s, mut r) = (inv, inv);
        for _ in 0..4 { r = r.rotate_left(1); s ^= r; }
        sbox[x as usize] = s ^ 0x63;
    }
    sbox
}
fn expand_key(key: &[u8; 16], sbox: &[u8; 256]) -> [u8; 176] {
    let mut w = [0u8; 176];
    w[..16].copy_from_slice(key);
    for i in 4..44 {
        let mut t = [w[4 * i - 4], w[4 * i - 3], w[4 * i - 2], w[4 * i - 1]];
        if i % 4 == 0 {
            t = [sbox[t[1] as usize] ^ RCON[i / 4 - 1], sbox[t[2] as usize], sbox[t[3] as usize], sbox[t[0] as usize]];
        }
        for j in 0..4 { w[4 * i + j] = w[4 * (i - 4) + j] ^ t[j]; }
    }
    w
}
fn encrypt_block_soft(rk: &[u8; 176], sbox: &[u8; 256], block: &[u8; 16]) -> [u8; 16] {
    let mut s = *block;
    for i in 0..16 { s[i] ^= rk[i]; }
    for round in 1..=10 {
        for b in s.iter_mut() { *b = sbox[*b as usize]; }
        // shift rows (state is column-major: s[4*c + r])
        let t = s;
        for c in 0..4 { for r in 0..4 { s[4 * c + r] = t[4 * ((c + r) % 4) + r]; } }
        if round != 10 {
            for c in 0..4 {
                let (a0, a1, a2, a3) = (s[4 * c], s[4 * c + 1], s[4 * c + 2], s[4 * c + 3]);
                s[4 * c] = gmul(a0, 2) ^ gmul(a1, 3) ^ a2 ^ a3;
                s[4 * c + 1] = a0 ^ gmul(a1, 2) ^ gmul(a2, 3) ^ a3;
                s[4 * c + 2] = a0 ^ a1 ^ gmul(a2, 2) ^ gmul(a3, 3);
                s[4 * c + 3] = gmul(a0, 3) ^ a1 ^ a2 ^ gmul(a3, 2);
            }
        }
        for i in 0..16 { s[i] ^= rk[16 * round + i]; }
    }
    s
}
fn cfb8_encrypt_soft(rk: &[u8; 176], sbox: &[u8; 256], iv: &[u8; 16], data: &[u8]) -> Vec<u8> {
    let mut reg = *iv;
    let mut out = Vec::with_capacity(data.len());
    for &p in data {
        let k = encrypt_block_soft(rk, sbox, &reg)[0];
        let c = p ^ k;
        out.push(c);
        reg.copy_within(1.., 0);
        reg[15] = c;
    }
    out
}

#[cfg(target_arch = "x86_64")]
mod ni {
    use std::arch::x86_64::*;
    #[target_feature(enable = "aes")]
    pub unsafe fn cfb8_encrypt(rk: &[u8; 176], iv: &[u8; 16], data: &[u8]) -> Vec<u8> {
        let k: Vec<__m128i> = (0..11).map(|i| _mm_loadu_si128(rk.as_ptr().add(16 * i) as *const __m128i)).collect();
        // window trick: register at step i is (iv ++ ciphertext)[i..i+16]
        let mut win = Vec::with_capacity(16 + data.len());
        win.extend_from_slice(iv);
        for (i, &p) in data.iter().enumerate() {
            let mut b = _mm_xor_si128(_mm_loadu_si128(win.as_ptr().add(i) as *const __m128i), k[0]);
            for r in 1..10 { b = _mm_aesenc_si128(b, k[r]); }
            b = _mm_aesenclast_si128(b, k[10]);
            let ks = _mm_cvtsi128_si32(b) as u8;
            win.push(p ^ ks);
        }
        win.split_off(16)
    }
    // Decryption knows all ciphertext up front, so four blocks can be in flight at once.
    #[target_feature(enable = "aes")]
    pub unsafe fn cfb8_decrypt(rk: &[u8; 176], iv: &[u8; 16], data: &[u8]) -> Vec<u8> {
        let k: Vec<__m128i> = (0..11).map(|i| _mm_loadu_si128(rk.as_ptr().add(16 * i) as *const __m128i)).collect();
        let mut win = Vec::with_capacity(16 + data.len());
        win.extend_from_slice(iv);
        win.extend_from_slice(data);
        let mut out = vec![0u8; data.len()];
        let enc = |x: __m128i| -> __m128i {
            let mut b = _mm_xor_si128(x, k[0]);
            for r in 1..10 { b = _mm_aesenc_si128(b, k[r]); }
            _mm_aesenclast_si128(b, k[10])
        };
        let mut i = 0;
        while i + 4 <= data.len() {
            let b0 = enc(_mm_loadu_si128(win.as_ptr().add(i) as *const __m128i));
            let b1 = enc(_mm_loadu_si128(win.as_ptr().add(i + 1) as *const __m128i));
            let b2 = enc(_mm_loadu_si128(win.as_ptr().add(i + 2) as *const __m128i));
            let b3 = enc(_mm_loadu_si128(win.as_ptr().add(i + 3) as *const __m128i));
            out[i] = data[i] ^ (_mm_cvtsi128_si32(b0) as u8);
            out[i + 1] = data[i + 1] ^ (_mm_cvtsi128_si32(b1) as u8);
            out[i + 2] = data[i + 2] ^ (_mm_cvtsi128_si32(b2) as u8);
            out[i + 3] = data[i + 3] ^ (_mm_cvtsi128_si32(b3) as u8);
            i += 4;
        }
        while i < data.len() {
            out[i] = data[i] ^ (_mm_cvtsi128_si32(enc(_mm_loadu_si128(win.as_ptr().add(i) as *const __m128i))) as u8);
            i += 1;
        }
        out
    }
}

fn main() {
    let dir = std::env::args().nth(1).expect("usage: gwbench DATA_DIR");
    let reps: u32 = std::env::var("REPS").ok().and_then(|s| s.parse().ok()).unwrap_or(5);
    let rd = |f: &str| fs::read(format!("{}/{}", dir, f)).unwrap();
    let varints = rd("varints.bin");
    let vals: Vec<u32> = rd("vals.bin").chunks_exact(4).map(|c| u32::from_le_bytes(c.try_into().unwrap())).collect();
    let frames = rd("frames.bin");
    let posbin = rd("pos.bin");
    let payloads: Vec<[u8; 33]> = posbin.chunks_exact(33).map(|c| c.try_into().unwrap()).collect();
    let chunk = rd("chunk.bin");

    let (c, s) = bench("vi_decode", 1_000_000, varints.len() as u64, reps, || vi_decode_all(black_box(&varints)));
    println!("RESULT vi_decode count={} sum={}", c, s);
    let enc = bench("vi_encode", 1_000_000, varints.len() as u64, reps, || vi_encode_all(black_box(&vals)));
    println!("RESULT vi_encode len={} ok={}", enc.len(), (enc == varints) as u8);
    for name in ["split_scan", "split_index"] {
        let (f, i, b) = bench(name, 200_000, frames.len() as u64, reps, || split_frames(black_box(&frames)));
        println!("RESULT {} frames={} idsum={} bodybytes={}", name, f, i, b);
    }
    let (sx, sf) = bench("pos_decode", 200_000, 200_000 * 33, reps, || pos_decode_loop(black_box(&payloads), 200_000));
    println!("RESULT pos_decode sx={:.6} flags={}", sx, sf);
    let fo = bench("build_frames", 200_000, 6_400_000, reps, || build_frames(black_box(200_000)));
    println!("RESULT build_frames len={} ok={}", fo.len(), (fo == rd("frames_out.bin")) as u8);
    let (m, ch, o, b) = bench("coro", 200_000, 0, reps, || run_conns(black_box(2000), 100));
    println!("RESULT coro moves={} chats={} other={} bytes={}", m, ch, o, b);

    // zlib: system libz through FFI, level 6, same as `zlib compress $data 6` in Tcl
    let bound = unsafe { compressBound(chunk.len() as c_ulong) } as usize;
    let mut zbuf = vec![0u8; bound];
    let mut zlen = 0usize;
    bench("z_compress", 1, chunk.len() as u64, reps, || unsafe {
        let mut dl = bound as c_ulong;
        assert_eq!(compress2(zbuf.as_mut_ptr(), &mut dl, chunk.as_ptr(), chunk.len() as c_ulong, 6), 0);
        zlen = dl as usize;
    });
    let mut back = vec![0u8; chunk.len()];
    bench("z_decompress", 1, chunk.len() as u64, reps, || unsafe {
        let mut dl = back.len() as c_ulong;
        assert_eq!(uncompress(back.as_mut_ptr(), &mut dl, zbuf.as_ptr(), zlen as c_ulong), 0);
    });
    println!("RESULT z_roundtrip ok={}", (back == chunk) as u8);
    println!("INFO z_compress clen={}", zlen);

    // AES-128-CFB8, key 00..0f, iv 10..1f
    let key: [u8; 16] = std::array::from_fn(|i| i as u8);
    let iv: [u8; 16] = std::array::from_fn(|i| 16 + i as u8);
    let sbox = make_sbox();
    let rk = expand_key(&key, &sbox);
    let expected = rd("aes_expected.bin");
    let n = chunk.len() as u64;
    let soft = bench("aes_cfb8_soft", n, n, reps.min(3), || cfb8_encrypt_soft(&rk, &sbox, &iv, black_box(&chunk)));
    println!("RESULT aes_cfb8_soft len={} ok={}", soft.len(), (soft == expected) as u8);
    #[cfg(target_arch = "x86_64")]
    if is_x86_feature_detected!("aes") {
        let ni_enc = bench("aes_cfb8", n, n, reps, || unsafe { ni::cfb8_encrypt(&rk, &iv, black_box(&chunk)) });
        println!("RESULT aes_cfb8 len={} ok={}", ni_enc.len(), (ni_enc == expected) as u8);
        let ni_dec = bench("aes_cfb8_dec", n, n, reps, || unsafe { ni::cfb8_decrypt(&rk, &iv, black_box(&expected)) });
        println!("RESULT aes_cfb8_dec len={} ok={}", ni_dec.len(), (ni_dec == chunk) as u8);
    } else {
        println!("INFO no AES-NI on this CPU");
    }
}
