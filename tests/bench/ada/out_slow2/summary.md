### Correctness

- Ada `-O2`: 40 checks OK, 2 partial (prefix equal), 0 wrong
- Ada `-O2 -gnatp`: 40 checks OK, 2 partial (prefix equal), 0 wrong
- Ada `-O2 -gnata`: 38 checks OK, 4 partial (prefix equal), 0 wrong
- Ada `-gnata (adacraft's own build, no -O)`: 38 checks OK, 4 partial (prefix equal), 0 wrong
- Rust baseline: all RESULT lines match the oracle

### Throughput (best of all rounds; ops/s, or MB/s for zlib and AES)

| benchmark | Ada `-O2` | Ada `-O2 -gnatp` | Ada `-O2 -gnata` | Ada `-gnata`, no -O | Rust | Ada `-O2` / Rust | `-gnatp` / `-O2` |
|---|---|---|---|---|---|---|---|
| VarInt decode, adacraft `Varnum.Decode_Varint` as-is | 117.95 M | 80.76 M | 108.58 M | 41.38 M | 299.20 M | 39% | 0.68x |
| VarInt decode, hand-written Ada loop | 241.92 M | 201.96 M | 250.20 M | 155.20 M | 299.20 M | 81% | 0.83x |
| VarInt encode, adacraft `Varnum.Encode` as-is (limited N, see notes) | 119.79 M | 119.90 M | 8.3 k | 8.6 k | 270.33 M | 44% | 1.00x |
| VarInt encode, adacraft `Varnum.Encode` as-is, 5-byte scratch like its own callers | 97.31 M | 135.65 M | 87.42 M | 21.93 M | 270.33 M | 36% | 1.39x |
| VarInt encode, hand-written Ada loop | 221.10 M | 269.78 M | 249.40 M | 95.26 M | 270.33 M | 82% | 1.22x |
| frame split, adacraft `Frame.Decode_Frame`, no body copy | 41.97 M | 40.27 M | 44.06 M | 17.34 M | 52.51 M | 80% | 0.96x |
| frame split, `Decode_Frame` + heap copy of each body | 24.03 M | 25.26 M | 24.74 M | 15.49 M | 55.25 M | 43% | 1.05x |
| frame split, hand-written loop + scratch copy | 26.53 M | 83.90 M | 27.52 M | 53.08 M | 55.25 M | 48% | 3.16x |
| frame split, adacraft stateful `Frame.Feed` (4 KiB reads, callback per frame) | 14.23 M | 22.59 M | 18.09 M | 8.73 M | 55.25 M | 26% | 1.59x |
| position decode (200k) | 44.23 M | 79.03 M | 56.18 M | 17.50 M | 257.24 M | 17% | 1.79x |
| build frames, adacraft `Packet_Encoder` as-is (limited N) | 13.6 k | 18.2 k | 17.6 k | 15.9 k | 77.43 M | 0.02% | 1.33x |
| build frames, hand-written Ada | 34.54 M | 87.12 M | 36.40 M | 8.49 M | 77.43 M | 45% | 2.52x |
| connections, plain loop (2000 conns x 100 pkts) | 342.95 M | 609.82 M | 442.11 M | 123.83 M | 717.01 M | 48% | 1.78x |
| connections, one Ada task per connection, no synchronisation | 1.44 M | 1.59 M | 1.33 M | 1.42 M | 717.01 M | 0.20% | 1.10x |
| connections, one Ada task per connection, rendezvous per packet | 19.7 k | 21.1 k | 18.4 k | 19.9 k | 717.01 M | 0.00% | 1.07x |
| zlib compress 1 MiB level 6 (adacraft binding) | 92.0 MB/s | 84.2 MB/s | 91.2 MB/s | 84.3 MB/s | 94.9 MB/s | 97% | 0.91x |
| zlib decompress 1 MiB | 718.6 MB/s | 653.7 MB/s | 734.8 MB/s | 662.1 MB/s | 746.0 MB/s | 96% | 0.91x |
| AES-128-CFB8 encrypt, portable Ada software | 0.5 MB/s | 0.5 MB/s | 0.5 MB/s | 0.1 MB/s | 7.5 MB/s | 6.93% | 0.97x |
| AES-128-CFB8 encrypt, OpenSSL EVP via Interfaces.C (1 MiB call) | 56.1 MB/s | 50.3 MB/s | 54.2 MB/s | 62.8 MB/s | 58.7 MB/s | 96% | 0.90x |
| AES-128-CFB8 decrypt, OpenSSL EVP (1 MiB call) | 65.0 MB/s | 60.2 MB/s | 57.6 MB/s | 66.2 MB/s | 515.1 MB/s | 13% | 0.93x |
| AES-128-CFB8 encrypt, OpenSSL EVP in 1000-byte calls | 57.4 MB/s | 56.2 MB/s | 56.3 MB/s | 62.8 MB/s | 58.7 MB/s | 98% | 0.98x |
| AES-128-CFB8 decrypt, OpenSSL EVP in 150-byte calls | 58.5 MB/s | 58.8 MB/s | 62.9 MB/s | 53.6 MB/s | 515.1 MB/s | 11% | 1.01x |

Notes: `Ada -O2 / Rust` is the Ada default build as a percentage of Rust (100% = equal). Rust AES numbers are AES-NI intrinsics; Rust 'frame split' copies each body (`to_vec`).

### Players one core can serve (gateway work only, 20 TPS => 50 ms budget per tick)

Same per-player assumptions as docs/TCL-EVALUATION.md: per tick 5 inbound packets (frame split + position decode), 25 outbound frames (about 1000 B), AES-CFB8 over 1000 B out and 150 B in.

| variant | framing + decode (us) | AES-CFB8 (us) | total per player-tick (us) | players/core (100% busy) | players/core (70% busy) |
|---|---|---|---|---|---|
| Ada `-O2`, adacraft code as-is, OpenSSL AES (per-message calls) | 1833.2 | 20.0 | 1853.2 | 27 | 19 |
| Ada `-O2`, hand-written loops, OpenSSL AES (per-message calls) | 1.0 | 20.0 | 21.0 | 2,378 | 1,665 |
| Ada `-O2 -gnatp`, hand-written loops, OpenSSL AES (per-message calls) | 0.4 | 20.4 | 20.8 | 2,408 | 1,686 |
| Ada `-O2`, hand-written loops, OpenSSL AES (1 MiB calls, like the Rust row) | 1.0 | 20.1 | 21.2 | 2,363 | 1,654 |
| Rust, AES-NI (this batch) | 0.4 | 17.3 | 17.8 | 2,813 | 1,969 |

    INFO ada reps=5
    INFO z_compress clen=99485
    INFO mismatches=0
    INFO ada reps=5
    INFO z_compress clen=99485
    INFO mismatches=0
    rust INFO z_compress clen=99485
    rust INFO z_compress clen=99485
