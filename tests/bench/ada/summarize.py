#!/usr/bin/env python3
"""Summarise the Ada batch: best of all rounds per benchmark, correctness, ratios to Rust, players per core.
usage: summarize.py OUT_DIR [OUT_DIR ...]   (reads <dir>/ada_<variant>.<round>.log and <dir>/rust.<round>.log of every directory; best of all runs;
expected RESULT lines from ../tcl/data/expected.txt)
"""
import glob, os, re, sys
dirs = sys.argv[1:]
here = os.path.dirname(os.path.abspath(__file__))
exp = {l.strip() for l in open(os.path.join(here, "..", "tcl", "data", "expected.txt")) if l.strip()}
VARIANTS = [("O2", "-O2"), ("O2_nochecks", "-O2 -gnatp"), ("O2_gnata", "-O2 -gnata"), ("adacraft_flags", "-gnata (adacraft's own build, no -O)")]

def load(patterns):
    best, units, nb, checks, info = {}, {}, {}, [], []
    for f in sorted(sum((glob.glob(p) for p in patterns), [])):
        for l in open(f):
            p = l.split()
            if l.startswith("BENCH "):
                n, s = p[1], float(p[2])
                if n not in best or s < best[n]:
                    best[n] = s; units[n] = int(p[3]); nb[n] = int(p[4])
            elif l.startswith("CHECK "):
                checks.append(l.strip())
            elif l.startswith("RESULT "):
                checks.append("RUST " + l.strip()) if "-- " not in l else None
            elif l.startswith("INFO "):
                info.append(l.strip())
    return best, units, nb, checks, info

ada = {v: load([f"{d}/ada_{v}.*.log" for d in dirs]) for v, _ in VARIANTS}
rust = load([f"{d}/rust.*.log" for d in dirs])

print("### Correctness\n")
for v, sw in VARIANTS:
    ch = ada[v][3]
    ok = sum(1 for c in ch if c.endswith(" OK")); part = sum(1 for c in ch if "PARTIAL" in c and "prefix_ok=1" in c)
    bad = [c for c in ch if "MISMATCH" in c or ("PARTIAL" in c and "prefix_ok=0" in c)]
    print(f"- Ada `{sw}`: {ok} checks OK, {part} partial (prefix equal), {len(bad)} wrong" + ("" if not bad else ": " + "; ".join(sorted(set(bad)))))
rres = {c[5:] for c in rust[3] if c.startswith("RUST ")}
rbad = sorted(r for r in rres if r not in exp and not r.startswith("RESULT aes_cfb8_soft") and not r.startswith("RESULT aes_cfb8_dec"))
print(f"- Rust baseline: {'all RESULT lines match the oracle' if not rbad else 'MISMATCH ' + '; '.join(rbad)}\n")

def rate(d, n):
    best, units, nb, *_ = d
    if n not in best: return None
    return units[n] / best[n], (nb[n] / best[n] / 1e6 if nb[n] else None)

def f(x):
    if x is None: return "-"
    return f"{x/1e6:.2f} M" if x >= 1e6 else f"{x/1e3:.1f} k" if x >= 1e3 else f"{x:.1f}"

# (label, ada bench, rust bench, mode) mode: ops or mb
ROWS = [
    ("VarInt decode, adacraft `Varnum.Decode_Varint` as-is", "vi_decode_asis", "vi_decode", "ops"),
    ("VarInt decode, hand-written Ada loop", "vi_decode_tight", "vi_decode", "ops"),
    ("VarInt encode, adacraft `Varnum.Encode` as-is (limited N, see notes)", "vi_encode_asis", "vi_encode", "ops"),
    ("VarInt encode, hand-written Ada loop", "vi_encode_tight", "vi_encode", "ops"),
    ("frame split, adacraft `Frame.Decode_Frame`, no body copy", "split_index_asis", "split_index", "ops"),
    ("frame split, `Decode_Frame` + heap copy of each body", "split_scan_asis", "split_scan", "ops"),
    ("frame split, hand-written loop + scratch copy", "split_tight", "split_scan", "ops"),
    ("frame split, adacraft stateful `Frame.Feed` (4 KiB reads, callback per frame)", "split_stream_asis", "split_scan", "ops"),
    ("position decode (200k)", "pos_decode", "pos_decode", "ops"),
    ("build frames, adacraft `Packet_Encoder` as-is (limited N)", "build_asis", "build_frames", "ops"),
    ("build frames, hand-written Ada", "build_tight", "build_frames", "ops"),
    ("connections, plain loop (2000 conns x 100 pkts)", "coro_plain", "coro", "ops"),
    ("connections, one Ada task per connection, no synchronisation", "coro_tasks_local", "coro", "ops"),
    ("connections, one Ada task per connection, rendezvous per packet", "coro_tasks_rdv", "coro", "ops"),
    ("zlib compress 1 MiB level 6 (adacraft binding)", "z_compress", "z_compress", "mb"),
    ("zlib decompress 1 MiB", "z_decompress", "z_decompress", "mb"),
    ("AES-128-CFB8 encrypt, portable Ada software", "aes_cfb8_soft", "aes_cfb8_soft", "mb"),
    ("AES-128-CFB8 encrypt, OpenSSL EVP via Interfaces.C (1 MiB call)", "aes_cfb8", "aes_cfb8", "mb"),
    ("AES-128-CFB8 decrypt, OpenSSL EVP (1 MiB call)", "aes_cfb8_dec", "aes_cfb8_dec", "mb"),
    ("AES-128-CFB8 encrypt, OpenSSL EVP in 1000-byte calls", "aes_cfb8_enc_1k_calls", "aes_cfb8", "mb"),
    ("AES-128-CFB8 decrypt, OpenSSL EVP in 150-byte calls", "aes_cfb8_dec_150_calls", "aes_cfb8_dec", "mb"),
]
print("### Throughput (best of all rounds; ops/s, or MB/s for zlib and AES)\n")
print("| benchmark | Ada `-O2` | Ada `-O2 -gnatp` | Ada `-O2 -gnata` | Ada `-gnata`, no -O | Rust | Ada `-O2` / Rust | `-gnatp` / `-O2` |")
print("|---|---|---|---|---|---|---|---|")
vals = {}
for label, a, r, mode in ROWS:
    cells = []
    for v, _ in VARIANTS:
        x = rate(ada[v], a)
        cells.append(None if x is None else (x[1] if mode == "mb" else x[0]))
    rr = rate(rust, r); rv = None if rr is None else (rr[1] if mode == "mb" else rr[0])
    vals[a] = cells + [rv]
    def fm(x): return "-" if x is None else (f"{x:.1f} MB/s" if mode == "mb" else f(x))
    ratio = "-" if cells[0] is None or rv is None else f"{cells[0]/rv*100:.0f}%" if cells[0]/rv >= 0.1 else f"{cells[0]/rv*100:.2f}%"
    chk = "-" if cells[0] is None or cells[1] is None else f"{cells[1]/cells[0]:.2f}x"
    print(f"| {label} | " + " | ".join(fm(c) for c in cells) + f" | {fm(rv)} | {ratio} | {chk} |")
print("\nNotes: `Ada -O2 / Rust` is the Ada default build as a percentage of Rust (100% = equal). Rust AES numbers are AES-NI intrinsics; Rust 'frame split' copies each body (`to_vec`).\n")

# ---- players per core, same per-player assumptions as docs/TCL-EVALUATION.md
def players(split, pos, build, enc_Bps, dec_Bps):
    fr = 5 * (1e6 / split + 1e6 / pos) + 25 * (1e6 / build)           # microseconds
    aes = 1000 / enc_Bps * 1e6 + 150 / dec_Bps * 1e6
    tot = fr + aes
    return fr, aes, tot, 50000 / tot, 0.7 * 50000 / tot

print("### Players one core can serve (gateway work only, 20 TPS => 50 ms budget per tick)\n")
print("Same per-player assumptions as docs/TCL-EVALUATION.md: per tick 5 inbound packets (frame split + position decode), 25 outbound frames (about 1000 B), AES-CFB8 over 1000 B out and 150 B in.\n")
print("| variant | framing + decode (us) | AES-CFB8 (us) | total per player-tick (us) | players/core (100% busy) | players/core (70% busy) |")
print("|---|---|---|---|---|---|")
def row(name, v_idx, split_n, build_n, aes_enc, aes_dec, src=None):
    try:
        g = lambda n: (vals[n][v_idx] if v_idx is not None else vals[n][-1])
        enc = g(aes_enc) * 1e6; dec = g(aes_dec) * 1e6
        r = players(g(split_n), g("pos_decode"), g(build_n), enc, dec)
        print(f"| {name} | {r[0]:.1f} | {r[1]:.1f} | {r[2]:.1f} | {r[3]:,.0f} | {r[4]:,.0f} |")
    except Exception as e:
        print(f"| {name} | n/a ({e}) | | | | |")
row("Ada `-O2`, adacraft code as-is, OpenSSL AES (per-message calls)", 0, "split_scan_asis", "build_asis", "aes_cfb8_enc_1k_calls", "aes_cfb8_dec_150_calls")
row("Ada `-O2`, hand-written loops, OpenSSL AES (per-message calls)", 0, "split_tight", "build_tight", "aes_cfb8_enc_1k_calls", "aes_cfb8_dec_150_calls")
row("Ada `-O2 -gnatp`, hand-written loops, OpenSSL AES (per-message calls)", 1, "split_tight", "build_tight", "aes_cfb8_enc_1k_calls", "aes_cfb8_dec_150_calls")
row("Ada `-O2`, hand-written loops, OpenSSL AES (1 MiB calls, like the Rust row)", 0, "split_tight", "build_tight", "aes_cfb8", "aes_cfb8_dec")
try:
    r = players(vals["split_tight"][-1], vals["pos_decode"][-1], vals["build_tight"][-1], vals["aes_cfb8"][-1] * 1e6, vals["aes_cfb8_dec"][-1] * 1e6)
    print(f"| Rust, AES-NI (this batch) | {r[0]:.1f} | {r[1]:.1f} | {r[2]:.1f} | {r[3]:,.0f} | {r[4]:,.0f} |")
except Exception as e:
    print(f"| Rust | n/a ({e}) | | | | |")
print()
for v, _ in VARIANTS[:1]:
    for l in ada[v][4]:
        print("    " + l)
for l in rust[4]:
    if "z_compress" in l: print("    rust " + l)
