//! `cfb8_tool enc|dec KEYHEX SEED < in > out`: AES-128-CFB8 (key = IV) over stdin, processed in random-sized chunks seeded by SEED,
//! so a shell test can compare the output with `openssl enc -aes-128-cfb8` for streams cut at arbitrary places (tests/gateway/cfb8_openssl.sh).

use dbcraft_gateway_core::aes::Cfb8;
use std::io::{Read, Write};

fn main() {
    let a: Vec<String> = std::env::args().collect();
    if a.len() != 4 {
        eprintln!("usage: cfb8_tool enc|dec KEYHEX SEED < in > out");
        std::process::exit(2);
    }
    let kb: Vec<u8> = (0..16).map(|i| u8::from_str_radix(&a[2][2 * i..2 * i + 2], 16).expect("hex key")).collect();
    let mut key = [0u8; 16];
    key.copy_from_slice(&kb);
    let mut seed: u64 = a[3].parse().expect("seed");
    let mut data = Vec::new();
    std::io::stdin().read_to_end(&mut data).unwrap();
    let mut c = Cfb8::new(&key);
    let mut o = 0;
    while o < data.len() {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        let n = 1 + (seed % 3000) as usize;
        let end = (o + n).min(data.len());
        if a[1] == "enc" {
            c.encrypt(&mut data[o..end]);
        } else {
            c.decrypt(&mut data[o..end]);
        }
        o = end;
    }
    std::io::stdout().write_all(&data).unwrap();
}
