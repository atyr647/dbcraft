#!/usr/bin/env python3
"""Summarize Elixir (+S 1 / +S 4) against Rust.  usage: summarize.py OUTDIR expected.txt"""
import glob, re, sys, os
out, expf = sys.argv[1], sys.argv[2]
def load(pattern):
    best, results, info = {}, set(), []
    for f in sorted(glob.glob(os.path.join(out, pattern))):
        for line in open(f, errors="replace"):
            p = line.split()
            if not p: continue
            if p[0] == "BENCH":
                t, u, b = float(p[2]), int(p[3]), int(p[4])
                if p[1] not in best or t < best[p[1]][0]: best[p[1]] = (t, u, b)
            elif p[0] == "RESULT": results.add(line.strip())
            elif p[0] == "INFO": info.append(line.strip())
    return best, results, info
rs, rres, _ = load("rust.*.log"); e1, r1, i1 = load("ex_s1.*.log"); e4, r4, i4 = load("ex_s4.*.log")
expected = [l.strip() for l in open(expf) if l.strip()]
alias = {"coro_single": "coro", "build_frames_bin": "build_frames"}
def check(res, label):
    names = {l.split()[1]: l for l in res}
    bad = []
    for l in expected:
        n = l.split()[1]
        if n not in names or names[n] != l: bad.append((n, names.get(n)))
    for a, b in alias.items():
        exp = next(l for l in expected if l.split()[1] == b).replace(f"RESULT {b} ", f"RESULT {a} ")
        if a in names and names[a] != exp: bad.append((a, names[a]))
    return f"- {label}: " + ("all RESULT lines match the oracle" if not bad else f"MISMATCH {bad}")
print("#### Correctness\n"); print(check(r1, "Elixir +S 1")); print(check(r4, "Elixir +S 4"))
print(f"- Rust: {len(rres)} RESULT lines (same oracle)\n")
def ops(b): t, u, by = b; return u / t if u > 1 else 1 / t
def mbs(b): t, u, by = b; return by / t / 1e6
def fmt(v): return f"{v/1e6:.2f} M" if v >= 1e6 else (f"{v/1e3:.1f} k" if v >= 1e3 else f"{v:.1f}")
rust_name = lambda n: alias.get(n, n)
rows = ["vi_decode", "vi_encode", "split_scan", "split_index", "pos_decode", "build_frames", "build_frames_bin", "coro", "coro_single",
        "z_compress", "z_decompress", "z_compress_128k", "z_decompress_128k", "aes_cfb8", "aes_cfb8_dec"]
print("\n#### Single-process throughput (best of all runs)\n")
print("| benchmark | Elixir +S 1 | Elixir +S 4 | Rust | Rust / Elixir(+S 1) |\n|---|---|---|---|---|")
for n in rows:
    if n not in e1: continue
    r = rs.get(rust_name(n)); unit = "MB/s" if n.startswith(("z_", "aes")) else "ops/s"
    f = (lambda b: f"{mbs(b):.1f} MB/s") if unit == "MB/s" else (lambda b: f"{fmt(ops(b))} ops/s")
    ratio = ""
    if r: ratio = f"{(mbs(r)/mbs(e1[n]) if unit=='MB/s' else ops(r)/ops(e1[n])):.1f}x"
    print(f"| {n} | {f(e1[n])} | {f(e4[n]) if n in e4 else ''} | {f(r) if r else 'n/a'} | {ratio} |")
print("\n#### AES-CFB8 call patterns (one connection's stream cut into calls; includes the call overhead)\n")
print("| pattern | +S 1 | +S 4 | us per call (+S 1) |\n|---|---|---|---|")
for n, size in (("aes_enc_1000B_calls", 1000), ("aes_dec_150B_calls", 150), ("aes_enc_64B_calls", 64)):
    if n in e1:
        t, u, by = e1[n]; calls = by / size
        print(f"| {n} | {mbs(e1[n]):.1f} MB/s | {mbs(e4[n]):.1f} MB/s | {t / calls * 1e6:.2f} |")
print("\n#### Multi-process scaling: 4 concurrent copies of the same work (aggregate throughput)\n")
print("| benchmark | single (+S 1) | 4 copies, +S 1 | 4 copies, +S 4 | speedup +S 4 vs +S 1 single |\n|---|---|---|---|---|")
pairs = [("vi_decode", "par_vi_decode"), ("split_scan", "par_split_scan"), ("split_index", "par_split_index"), ("pos_decode", "par_pos_decode"),
         ("build_frames", "par_build_frames"), ("coro", "par_coro"), ("aes_cfb8", "par_aes_cfb8"), ("aes_cfb8_dec", "par_aes_cfb8_dec"),
         ("aes_enc_1000B_calls", "par_aes_enc_1000B_calls"), ("aes_dec_150B_calls", "par_aes_dec_150B_calls"), ("z_compress", "par_z_compress"), ("z_decompress", "par_z_decompress")]
spd = {}
for s, p in pairs:
    if s in e1 and p in e1 and p in e4:
        single = ops(e1[s]); a = ops(e1[p]); b = ops(e4[p]); spd[s] = b / single
        print(f"| {s} | {fmt(single)} | {fmt(a)} ({a/single:.2f}x) | {fmt(b)} ({b/single:.2f}x) | {b/single:.2f}x |")
# players per core / per 4 schedulers, same per-player assumptions as docs/TCL-EVALUATION.md
def per_op(b): return 1 / ops(b)
def players(src, par=None):
    sp = lambda n: (ops(par[n]) / (1 if n not in ("par_coro",) else 1)) if par else None
    return None
t_split = per_op(e1["split_scan"]); t_pos = per_op(e1["pos_decode"]); t_build = per_op(e1["build_frames"])
enc_call = e1["aes_enc_1000B_calls"]; dec_call = e1["aes_dec_150B_calls"]
t_enc = 1000 / (mbs(enc_call) * 1e6); t_dec = 150 / (mbs(dec_call) * 1e6)
fr = 5 * t_split + 5 * t_pos + 25 * t_build
tot = fr + t_enc + t_dec
print("\n#### Players one core / four cores can serve (gateway work only; same assumptions as docs/TCL-EVALUATION.md)\n")
print("Per player per tick: 5 inbound packets (frame split + position decode), 25 outbound frames (about 1000 B), AES-CFB8 over 1000 B out and 150 B in, per-call pattern.\n")
print("| variant | framing + decode | AES-CFB8 | total per player-tick | players per core (100% busy) | players per core (70% busy) |\n|---|---|---|---|---|---|")
print(f"| Elixir +S 1 | {fr*1e6:.1f} us | {(t_enc+t_dec)*1e6:.1f} us | {tot*1e6:.1f} us | {0.05/tot:,.0f} | {0.035/tot:,.0f} |")
rr = rs
rt = 5 / ops(rr["split_index"]) + 5 / ops(rr["pos_decode"]) + 25 / ops(rr["build_frames"])
ra = 1000 / (mbs(rr["aes_cfb8"]) * 1e6) + 150 / (mbs(rr["aes_cfb8_dec"]) * 1e6)
print(f"| Rust, AES-NI | {rt*1e6:.1f} us | {ra*1e6:.1f} us | {(rt+ra)*1e6:.1f} us | {0.05/(rt+ra):,.0f} | {0.035/(rt+ra):,.0f} |")
if all(k in e4 for k in ("par_split_scan", "par_pos_decode", "par_build_frames", "par_aes_enc_1000B_calls", "par_aes_dec_150B_calls")):
    f4 = 5 / ops(e4["par_split_scan"]) + 5 / ops(e4["par_pos_decode"]) + 25 / ops(e4["par_build_frames"])
    a4 = 1000 / (mbs(e4["par_aes_enc_1000B_calls"]) * 1e6) + 150 / (mbs(e4["par_aes_dec_150B_calls"]) * 1e6)
    print(f"| Elixir +S 4, measured aggregate of 4 workers | {f4*1e6:.1f} us | {a4*1e6:.1f} us | {(f4+a4)*1e6:.1f} us | {0.05/(f4+a4):,.0f} on 4 cores | {0.035/(f4+a4):,.0f} on 4 cores |")
print("\nInfo lines: " + " | ".join(sorted(set(i1 + i4))))
