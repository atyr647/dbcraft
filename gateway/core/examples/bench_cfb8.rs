//! Throughput of the std-only AES-128-CFB8 (one direction, one stream): `bench_cfb8 [megabytes]`.  Best of 5 runs.
use dbcraft_gateway_core::aes::Cfb8;
use std::time::Instant;

fn main() {
    let mb: usize = std::env::args().nth(1).and_then(|s| s.parse().ok()).unwrap_or(32);
    let key = [0x42u8; 16];
    let mut data = vec![0xa5u8; mb * 1024 * 1024];
    for dir in ["encrypt", "decrypt"] {
        let mut best = f64::MAX;
        for _ in 0..5 {
            let mut c = Cfb8::new(&key);
            let t = Instant::now();
            if dir == "encrypt" { c.encrypt(&mut data) } else { c.decrypt(&mut data) }
            best = best.min(t.elapsed().as_secs_f64());
        }
        println!("{dir}: {:.1} MB/s (best of 5, {mb} MB)", mb as f64 / best);
    }
}
