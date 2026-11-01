#!/usr/bin/env python3
"""Summarize interp/aot/rust logs: min seconds over rounds, verify RESULT lines, estimate players per core."""
import glob, re, sys
out, expf, aes_bytes = sys.argv[1], sys.argv[2], int(sys.argv[3])
exp = [l.strip() for l in open(expf) if l.strip()]
def load(mode):
    best, units, nbytes, results = {}, {}, {}, []
    for f in sorted(glob.glob(f"{out}/{mode}.*.log")):
        for l in open(f):
            if l.startswith("BENCH "):
                _, n, s, u, b = l.split(); s = float(s)
                if n not in best or s < best[n]: best[n] = s
                units[n] = int(u); nbytes[n] = int(b)
            elif l.startswith("RESULT "): results.append(l.strip())
    return best, units, nbytes, results
M = {m: load(m) for m in ("interp", "aot", "rust")}
# --- correctness vs the Python oracle
def norm(l):  # AES length differs when run on a prefix
    return re.sub(r"len=\d+", "len=*", l) if l.startswith("RESULT aes_cfb8 ") else l
want = {norm(l) for l in exp}
print("### Correctness (every RESULT line vs the Python/openssl oracle)\n")
for m, (_, _, _, res) in M.items():
    bad = sorted({norm(r) for r in res} - want - {norm(r) for r in res if r.startswith("RESULT aes_cfb8_")})
    print(f"- {m}: {'all RESULT lines match' if not bad else 'MISMATCH: ' + '; '.join(bad)} ({len(set(res))} distinct lines)")
print()
names = ["vi_decode", "vi_encode", "split_scan", "split_index", "pos_decode", "build_frames", "coro", "z_compress", "z_decompress", "aes_cfb8"]
label = {"vi_decode": "VarInt decode (1M varints)", "vi_encode": "VarInt encode (1M varints)", "split_scan": "frame split, `binary scan @off` (200k frames)",
         "split_index": "frame split, `scan cu*` + lindex (200k frames)", "pos_decode": "position decode (200k)", "build_frames": "build frames (200k)",
         "coro": "coroutine state machines (2000 conns x 100 pkts)", "z_compress": "zlib compress 1 MiB, level 6", "z_decompress": "zlib decompress 1 MiB",
         "aes_cfb8": f"AES-128-CFB8 encrypt ({aes_bytes // 1024} KiB)"}
def rate(m, n):
    best, units, nb, _ = M[m]
    if n not in best: return None
    return units[n] / best[n], (nb[n] / best[n] / 1e6 if nb[n] else None), best[n]
def fmt(x):
    if x is None: return "-"
    return f"{x/1e6:.2f} M" if x >= 1e6 else f"{x/1e3:.1f} k" if x >= 1e3 else f"{x:.1f}"
print("### Throughput (best of all runs; ops = the unit in the first column)\n")
print("| benchmark | Tcl interpreter | Tcl + tcl-aot | Rust | aot / interp | Rust / aot |")
print("|---|---|---|---|---|---|")
for n in names:
    ri, ra, rr = rate("interp", n), rate("aot", n), rate("rust", n)
    def cell(r, n):
        if r is None: return "-"
        s = fmt(r[0]) + " ops/s" if n not in ("z_compress", "z_decompress", "aes_cfb8") else ""
        if r[1] is not None: s = (s + (f" ({r[1]:.1f} MB/s)" if r[1] >= 1 else f" ({r[1]*1000:.1f} kB/s)")).strip()
        return s
    sp = f"{ra[0]/ri[0]:.2f}x" if ri and ra else "-"
    rs = f"{rr[0]/ra[0]:.0f}x" if rr and ra else "-"
    print(f"| {label[n]} | {cell(ri,n)} | {cell(ra,n)} | {cell(rr,n)} | {sp} | {rs} |")
print()
rb = M["rust"][0]
print("Rust AES: software (std only) %.1f MB/s; AES-NI encrypt %.1f MB/s; AES-NI decrypt (4 blocks in flight) %.1f MB/s\n" % (
    1048576 / rb["aes_cfb8_soft"] / 1e6, 1048576 / rb["aes_cfb8"] / 1e6, 1048576 / rb["aes_cfb8_dec"] / 1e6))
# --- players per core: per player per tick, 5 inbound packets (frame split + position decode), 25 outbound frames (~40 B each = 1000 B/tick),
#     AES-CFB8 on 1000 B out (encrypt) + 150 B in (decrypt)
def per(mode, n, units):
    best, u, _, _ = M[mode]; return best[n] / u[n] * units
def aes_cost(mode):
    best, u, _, _ = M[mode]
    if mode == "rust": return 1000 * best["aes_cfb8"] / u["aes_cfb8"] + 150 * best["aes_cfb8_dec"] / u["aes_cfb8_dec"]
    return 1150 * best["aes_cfb8"] / u["aes_cfb8"]
nat = aes_cost("rust")
print("### Players one core can serve (gateway work only, 20 TPS => 50 ms budget per tick)\n")
print("Per player per tick: 5 inbound packets (frame split + position decode), 25 outbound frames (about 1000 B), AES-CFB8 over 1000 B out + 150 B in.\n")
print("| variant | framing + decode | AES-CFB8 | total per player-tick | players per core (100% busy) | players per core (70% busy) |")
print("|---|---|---|---|---|---|")
def n(x): return f"{x:,.0f}" if x >= 10 else f"{x:.2f}"
for mode, title in (("interp", "Tcl interpreter, pure-Tcl AES"), ("aot", "Tcl + tcl-aot, pure-Tcl AES"), ("interp", "Tcl interpreter, native AES (Rust AES-NI rates)"),
                    ("aot", "Tcl + tcl-aot, native AES (Rust AES-NI rates)"), ("rust", "Rust, AES-NI")):
    base = 5 * (per(mode, "split_index", 1) + per(mode, "pos_decode", 1)) + 25 * per(mode, "build_frames", 1)
    a = nat if ("native" in title or mode == "rust") else aes_cost(mode)
    c = base + a
    print(f"| {title} | {base*1e6:.1f} us | {a*1e6:.1f} us | {c*1e6:,.1f} us | {n(0.050/c)} | {n(0.035/c)} |")
