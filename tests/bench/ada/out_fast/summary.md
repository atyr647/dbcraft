### Correctness

- Ada `-O2`: 54 checks OK, 0 partial (prefix equal), 0 wrong
- Ada `-O2 -gnatp`: 54 checks OK, 0 partial (prefix equal), 0 wrong
- Ada `-O2 -gnata`: 51 checks OK, 3 partial (prefix equal), 0 wrong
- Ada `-gnata (adacraft's own build, no -O)`: 51 checks OK, 3 partial (prefix equal), 0 wrong
- Rust baseline: all RESULT lines match the oracle

### Throughput (best of all rounds; ops/s, or MB/s for zlib and AES)

| benchmark | Ada `-O2` | Ada `-O2 -gnatp` | Ada `-O2 -gnata` | Ada `-gnata`, no -O | Rust | Ada `-O2` / Rust | `-gnatp` / `-O2` |
|---|---|---|---|---|---|---|---|
| VarInt decode, adacraft `Varnum.Decode_Varint` as-is | 107.27 M | 126.24 M | 107.33 M | 47.51 M | 296.89 M | 36% | 1.18x |
| VarInt decode, hand-written Ada loop | 211.66 M | 258.99 M | 238.18 M | 175.15 M | 296.89 M | 71% | 1.22x |
| VarInt encode, adacraft `Varnum.Encode` as-is (limited N, see notes) | 106.38 M | 178.33 M | 7.5 k | 8.7 k | 246.09 M | 43% | 1.68x |
| VarInt encode, hand-written Ada loop | 196.58 M | 266.04 M | 236.88 M | 97.40 M | 246.09 M | 80% | 1.35x |
| frame split, adacraft `Frame.Decode_Frame`, no body copy | 37.40 M | 39.51 M | 42.31 M | 17.86 M | 47.81 M | 78% | 1.06x |
| frame split, `Decode_Frame` + heap copy of each body | 20.20 M | 24.27 M | 22.83 M | 13.12 M | 49.22 M | 41% | 1.20x |
| frame split, hand-written loop + scratch copy | 22.57 M | 82.44 M | 26.39 M | 45.04 M | 49.22 M | 46% | 3.65x |
| frame split, adacraft stateful `Frame.Feed` (4 KiB reads, callback per frame) | 13.06 M | 20.82 M | 16.58 M | 7.21 M | 49.22 M | 27% | 1.59x |
| position decode (200k) | 45.85 M | 74.09 M | 53.33 M | 14.39 M | 234.40 M | 20% | 1.62x |
| build frames, adacraft `Packet_Encoder` as-is (limited N) | - | - | - | - | 70.09 M | - | - |
| build frames, hand-written Ada | 28.38 M | 84.90 M | 34.86 M | 7.65 M | 70.09 M | 40% | 2.99x |
| connections, plain loop (2000 conns x 100 pkts) | 389.45 M | 609.04 M | 445.98 M | 123.27 M | 657.06 M | 59% | 1.56x |
| connections, one Ada task per connection, no synchronisation | 1.43 M | 1.46 M | 1.40 M | 1.48 M | 657.06 M | 0.22% | 1.03x |
| connections, one Ada task per connection, rendezvous per packet | - | - | - | - | 657.06 M | - | - |
| zlib compress 1 MiB level 6 (adacraft binding) | 92.4 MB/s | 84.3 MB/s | 84.3 MB/s | 106.8 MB/s | 84.4 MB/s | 109% | 0.91x |
| zlib decompress 1 MiB | 731.7 MB/s | 662.5 MB/s | 664.5 MB/s | 834.5 MB/s | 665.6 MB/s | 110% | 0.91x |
| AES-128-CFB8 encrypt, portable Ada software | - | - | - | - | 7.0 MB/s | - | - |
| AES-128-CFB8 encrypt, OpenSSL EVP via Interfaces.C (1 MiB call) | 59.6 MB/s | 50.2 MB/s | 58.7 MB/s | 62.6 MB/s | 61.8 MB/s | 97% | 0.84x |
| AES-128-CFB8 decrypt, OpenSSL EVP (1 MiB call) | 66.0 MB/s | 55.8 MB/s | 53.2 MB/s | 67.8 MB/s | 547.7 MB/s | 12% | 0.85x |
| AES-128-CFB8 encrypt, OpenSSL EVP in 1000-byte calls | 63.3 MB/s | 50.7 MB/s | 49.6 MB/s | 63.7 MB/s | 61.8 MB/s | 102% | 0.80x |
| AES-128-CFB8 decrypt, OpenSSL EVP in 150-byte calls | 66.7 MB/s | 61.2 MB/s | 54.2 MB/s | 68.1 MB/s | 547.7 MB/s | 12% | 0.92x |

Notes: `Ada -O2 / Rust` is the Ada default build as a percentage of Rust (100% = equal). Rust AES numbers are AES-NI intrinsics; Rust 'frame split' copies each body (`to_vec`).

### Players one core can serve (gateway work only, 20 TPS => 50 ms budget per tick)

Same per-player assumptions as docs/TCL-EVALUATION.md: per tick 5 inbound packets (frame split + position decode), 25 outbound frames (about 1000 B), AES-CFB8 over 1000 B out and 150 B in.

| variant | framing + decode (us) | AES-CFB8 (us) | total per player-tick (us) | players/core (100% busy) | players/core (70% busy) |
|---|---|---|---|---|---|
| Ada `-O2`, adacraft code as-is, OpenSSL AES (per-message calls) | n/a (unsupported operand type(s) for /: 'float' and 'NoneType') | | | | |
| Ada `-O2`, hand-written loops, OpenSSL AES (per-message calls) | 1.2 | 18.1 | 19.3 | 2,595 | 1,817 |
| Ada `-O2 -gnatp`, hand-written loops, OpenSSL AES (per-message calls) | 0.4 | 22.2 | 22.6 | 2,212 | 1,548 |
| Ada `-O2`, hand-written loops, OpenSSL AES (1 MiB calls, like the Rust row) | 1.2 | 19.0 | 20.3 | 2,469 | 1,728 |
| Rust, AES-NI (this batch) | 0.5 | 16.5 | 16.9 | 2,952 | 2,066 |