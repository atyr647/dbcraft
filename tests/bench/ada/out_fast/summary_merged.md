### Correctness

- Ada `-O2`: 92 checks OK, 2 partial (prefix equal), 0 wrong
- Ada `-O2 -gnatp`: 92 checks OK, 2 partial (prefix equal), 0 wrong
- Ada `-O2 -gnata`: 87 checks OK, 7 partial (prefix equal), 0 wrong
- Ada `-gnata (adacraft's own build, no -O)`: 87 checks OK, 7 partial (prefix equal), 0 wrong
- Rust baseline: all RESULT lines match the oracle

### Throughput (best of all rounds; ops/s, or MB/s for zlib and AES)

| benchmark | Ada `-O2` | Ada `-O2 -gnatp` | Ada `-O2 -gnata` | Ada `-gnata`, no -O | Rust | Ada `-O2` / Rust | `-gnatp` / `-O2` |
|---|---|---|---|---|---|---|---|
| VarInt decode, adacraft `Varnum.Decode_Varint` as-is | 107.27 M | 126.24 M | 107.33 M | 47.51 M | 296.89 M | 36% | 1.18x |
| VarInt decode, hand-written Ada loop | 211.66 M | 258.99 M | 238.18 M | 175.15 M | 296.89 M | 71% | 1.22x |
| VarInt encode, adacraft `Varnum.Encode` as-is (limited N, see notes) | 106.38 M | 178.33 M | 7.5 k | 8.7 k | 250.63 M | 42% | 1.68x |
| VarInt encode, hand-written Ada loop | 196.58 M | 266.04 M | 248.63 M | 97.40 M | 250.63 M | 78% | 1.35x |
| frame split, adacraft `Frame.Decode_Frame`, no body copy | 37.40 M | 39.56 M | 42.31 M | 17.86 M | 48.11 M | 78% | 1.06x |
| frame split, `Decode_Frame` + heap copy of each body | 21.55 M | 24.27 M | 23.48 M | 13.43 M | 49.73 M | 43% | 1.13x |
| frame split, hand-written loop + scratch copy | 24.49 M | 82.44 M | 28.45 M | 45.04 M | 49.73 M | 49% | 3.37x |
| frame split, adacraft stateful `Frame.Feed` (4 KiB reads, callback per frame) | 14.47 M | 20.82 M | 16.77 M | 7.27 M | 49.73 M | 29% | 1.44x |
| position decode (200k) | 47.72 M | 76.19 M | 53.33 M | 18.02 M | 235.77 M | 20% | 1.60x |
| build frames, adacraft `Packet_Encoder` as-is (limited N) | 15.8 k | 14.8 k | 14.5 k | 14.4 k | 70.23 M | 0.02% | 0.94x |
| build frames, hand-written Ada | 30.41 M | 88.18 M | 34.86 M | 8.00 M | 70.23 M | 43% | 2.90x |
| connections, plain loop (2000 conns x 100 pkts) | 439.63 M | 738.06 M | 445.98 M | 123.27 M | 657.11 M | 67% | 1.68x |
| connections, one Ada task per connection, no synchronisation | 1.43 M | 1.49 M | 1.60 M | 1.48 M | 657.11 M | 0.22% | 1.05x |
| connections, one Ada task per connection, rendezvous per packet | 19.0 k | 27.1 k | 22.0 k | 16.2 k | 657.11 M | 0.00% | 1.43x |
| zlib compress 1 MiB level 6 (adacraft binding) | 92.4 MB/s | 84.3 MB/s | 84.3 MB/s | 106.8 MB/s | 84.7 MB/s | 109% | 0.91x |
| zlib decompress 1 MiB | 731.7 MB/s | 662.5 MB/s | 664.5 MB/s | 834.5 MB/s | 665.6 MB/s | 110% | 0.91x |
| AES-128-CFB8 encrypt, portable Ada software | 0.5 MB/s | 0.5 MB/s | 0.6 MB/s | 0.1 MB/s | 7.0 MB/s | 7.35% | 0.90x |
| AES-128-CFB8 encrypt, OpenSSL EVP via Interfaces.C (1 MiB call) | 59.6 MB/s | 64.2 MB/s | 58.7 MB/s | 62.6 MB/s | 64.7 MB/s | 92% | 1.08x |
| AES-128-CFB8 decrypt, OpenSSL EVP (1 MiB call) | 66.0 MB/s | 68.7 MB/s | 55.5 MB/s | 67.8 MB/s | 547.7 MB/s | 12% | 1.04x |
| AES-128-CFB8 encrypt, OpenSSL EVP in 1000-byte calls | 63.3 MB/s | 64.2 MB/s | 53.2 MB/s | 63.7 MB/s | 64.7 MB/s | 98% | 1.01x |
| AES-128-CFB8 decrypt, OpenSSL EVP in 150-byte calls | 66.7 MB/s | 68.6 MB/s | 58.3 MB/s | 68.1 MB/s | 547.7 MB/s | 12% | 1.03x |

Notes: `Ada -O2 / Rust` is the Ada default build as a percentage of Rust (100% = equal). Rust AES numbers are AES-NI intrinsics; Rust 'frame split' copies each body (`to_vec`).

### Players one core can serve (gateway work only, 20 TPS => 50 ms budget per tick)

Same per-player assumptions as docs/TCL-EVALUATION.md: per tick 5 inbound packets (frame split + position decode), 25 outbound frames (about 1000 B), AES-CFB8 over 1000 B out and 150 B in.

| variant | framing + decode (us) | AES-CFB8 (us) | total per player-tick (us) | players/core (100% busy) | players/core (70% busy) |
|---|---|---|---|---|---|
| Ada `-O2`, adacraft code as-is, OpenSSL AES (per-message calls) | 1585.9 | 18.1 | 1604.0 | 31 | 22 |
| Ada `-O2`, hand-written loops, OpenSSL AES (per-message calls) | 1.1 | 18.1 | 19.2 | 2,606 | 1,824 |
| Ada `-O2 -gnatp`, hand-written loops, OpenSSL AES (per-message calls) | 0.4 | 17.8 | 18.2 | 2,751 | 1,926 |
| Ada `-O2`, hand-written loops, OpenSSL AES (1 MiB calls, like the Rust row) | 1.1 | 19.0 | 20.2 | 2,479 | 1,735 |
| Rust, AES-NI (this batch) | 0.5 | 15.7 | 16.2 | 3,084 | 2,159 |

    INFO ada reps=5
    INFO z_compress clen=99485
    INFO mismatches=0
    INFO ada reps=5
    INFO z_compress clen=99485
    INFO mismatches=0
    INFO ada reps=5
    INFO z_compress clen=99485
    INFO mismatches=0
    INFO ada reps=5
    INFO z_compress clen=99485
    INFO mismatches=0
    INFO ada reps=5
    INFO z_compress clen=99485
    INFO mismatches=0
    rust INFO z_compress clen=99485
    rust INFO z_compress clen=99485
    rust INFO z_compress clen=99485
    rust INFO z_compress clen=99485
    rust INFO z_compress clen=99485
