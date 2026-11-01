### Correctness

- Ada `-O2`: 38 checks OK, 2 partial (prefix equal), 0 wrong
- Ada `-O2 -gnatp`: 38 checks OK, 2 partial (prefix equal), 0 wrong
- Ada `-O2 -gnata`: 36 checks OK, 4 partial (prefix equal), 0 wrong
- Ada `-gnata (adacraft's own build, no -O)`: 36 checks OK, 4 partial (prefix equal), 0 wrong
- Rust baseline: all RESULT lines match the oracle

### Throughput (best of all rounds; ops/s, or MB/s for zlib and AES)

| benchmark | Ada `-O2` | Ada `-O2 -gnatp` | Ada `-O2 -gnata` | Ada `-gnata`, no -O | Rust | Ada `-O2` / Rust | `-gnatp` / `-O2` |
|---|---|---|---|---|---|---|---|
| VarInt decode, adacraft `Varnum.Decode_Varint` as-is | 99.55 M | 89.85 M | 89.31 M | 37.47 M | 270.05 M | 37% | 0.90x |
| VarInt decode, hand-written Ada loop | 207.17 M | 222.98 M | 203.12 M | 152.24 M | 270.05 M | 77% | 1.08x |
| VarInt encode, adacraft `Varnum.Encode` as-is (limited N, see notes) | 100.70 M | 118.70 M | 7.8 k | 8.0 k | 250.63 M | 40% | 1.18x |
| VarInt encode, hand-written Ada loop | 196.36 M | 243.87 M | 248.63 M | 96.61 M | 250.63 M | 78% | 1.24x |
| frame split, adacraft `Frame.Decode_Frame`, no body copy | 37.30 M | 39.56 M | 41.77 M | 17.84 M | 48.11 M | 78% | 1.06x |
| frame split, `Decode_Frame` + heap copy of each body | 21.55 M | 23.62 M | 23.48 M | 13.43 M | 49.73 M | 43% | 1.10x |
| frame split, hand-written loop + scratch copy | 24.49 M | 79.01 M | 28.45 M | 44.72 M | 49.73 M | 49% | 3.23x |
| frame split, adacraft stateful `Frame.Feed` (4 KiB reads, callback per frame) | 14.47 M | 20.70 M | 16.77 M | 7.27 M | 49.73 M | 29% | 1.43x |
| position decode (200k) | 47.72 M | 76.19 M | 43.99 M | 18.02 M | 235.77 M | 20% | 1.60x |
| build frames, adacraft `Packet_Encoder` as-is (limited N) | 15.8 k | 14.8 k | 14.5 k | 14.4 k | 70.23 M | 0.02% | 0.94x |
| build frames, hand-written Ada | 30.41 M | 88.18 M | 28.61 M | 8.00 M | 70.23 M | 43% | 2.90x |
| connections, plain loop (2000 conns x 100 pkts) | 439.63 M | 738.06 M | 442.02 M | 122.76 M | 657.11 M | 67% | 1.68x |
| connections, one Ada task per connection, no synchronisation | 1.37 M | 1.49 M | 1.60 M | 256.9 k | 657.11 M | 0.21% | 1.09x |
| connections, one Ada task per connection, rendezvous per packet | 19.0 k | 27.1 k | 22.0 k | 16.2 k | 657.11 M | 0.00% | 1.43x |
| zlib compress 1 MiB level 6 (adacraft binding) | 83.8 MB/s | 83.8 MB/s | 82.4 MB/s | 82.8 MB/s | 84.7 MB/s | 99% | 1.00x |
| zlib decompress 1 MiB | 657.5 MB/s | 658.3 MB/s | 646.4 MB/s | 645.8 MB/s | 662.7 MB/s | 99% | 1.00x |
| AES-128-CFB8 encrypt, portable Ada software | 0.5 MB/s | 0.5 MB/s | 0.6 MB/s | 0.1 MB/s | 6.5 MB/s | 7.89% | 0.90x |
| AES-128-CFB8 encrypt, OpenSSL EVP via Interfaces.C (1 MiB call) | 50.2 MB/s | 64.2 MB/s | 52.4 MB/s | 49.9 MB/s | 64.7 MB/s | 78% | 1.28x |
| AES-128-CFB8 decrypt, OpenSSL EVP (1 MiB call) | 53.8 MB/s | 68.7 MB/s | 55.5 MB/s | 52.5 MB/s | 514.8 MB/s | 10% | 1.28x |
| AES-128-CFB8 encrypt, OpenSSL EVP in 1000-byte calls | 50.4 MB/s | 64.2 MB/s | 53.2 MB/s | 50.2 MB/s | 64.7 MB/s | 78% | 1.27x |
| AES-128-CFB8 decrypt, OpenSSL EVP in 150-byte calls | 53.7 MB/s | 68.6 MB/s | 58.3 MB/s | 58.6 MB/s | 514.8 MB/s | 10% | 1.28x |

Notes: `Ada -O2 / Rust` is the Ada default build as a percentage of Rust (100% = equal). Rust AES numbers are AES-NI intrinsics; Rust 'frame split' copies each body (`to_vec`).

### Players one core can serve (gateway work only, 20 TPS => 50 ms budget per tick)

Same per-player assumptions as docs/TCL-EVALUATION.md: per tick 5 inbound packets (frame split + position decode), 25 outbound frames (about 1000 B), AES-CFB8 over 1000 B out and 150 B in.

| variant | framing + decode (us) | AES-CFB8 (us) | total per player-tick (us) | players/core (100% busy) | players/core (70% busy) |
|---|---|---|---|---|---|
| Ada `-O2`, adacraft code as-is, OpenSSL AES (per-message calls) | 1585.9 | 22.6 | 1608.5 | 31 | 22 |
| Ada `-O2`, hand-written loops, OpenSSL AES (per-message calls) | 1.1 | 22.6 | 23.8 | 2,105 | 1,474 |
| Ada `-O2 -gnatp`, hand-written loops, OpenSSL AES (per-message calls) | 0.4 | 17.8 | 18.2 | 2,751 | 1,926 |
| Ada `-O2`, hand-written loops, OpenSSL AES (1 MiB calls, like the Rust row) | 1.1 | 22.7 | 23.9 | 2,096 | 1,467 |
| Rust, AES-NI (this batch) | 0.5 | 15.7 | 16.2 | 3,081 | 2,157 |

    INFO ada reps=5
    INFO z_compress clen=99485
    INFO mismatches=0
    INFO ada reps=5
    INFO z_compress clen=99485
    INFO mismatches=0
    rust INFO z_compress clen=99485
    rust INFO z_compress clen=99485
