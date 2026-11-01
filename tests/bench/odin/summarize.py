#!/usr/bin/env python3
"""Merge BENCH lines (best over all rounds) and check RESULT lines against the oracle.  usage: summarize.py OUT_DIR expected.txt"""
import glob, os, sys
out, exp = sys.argv[1], sys.argv[2]
expected = set(l.strip() for l in open(exp) if l.startswith("RESULT"))
def load(prefix):
    best, results = {}, set()
    for f in sorted(glob.glob(f"{out}/{prefix}.*.log")):
        for l in open(f):
            p = l.split()
            if l.startswith("BENCH"):
                n, t, u, b = p[1], float(p[2]), int(p[3]), int(p[4])
                if n not in best or t < best[n][0]: best[n] = (t, u, b)
            elif l.startswith("RESULT"): results.add(l.strip())
    return best, results
R, rr = load("rust"); C, rc = load("odin_checked"); U, ru = load("odin_unchecked")
for name, res in (("rust", rr), ("odin checked", rc), ("odin unchecked", ru)):
    missing = expected - res
    print(f"- {name}: {'all oracle RESULT lines match' if not missing else 'MISSING/DIFFERENT: ' + str(sorted(missing))}; not-ok lines: {sorted(l for l in res if 'ok=0' in l)}")
print()
def rate(t, u, b, byte_rate):
    return f"{b / t / 1e6:,.1f} MB/s" if byte_rate else f"{u / t / 1e6:,.2f} M ops/s"
PAIR = {"split_arena":"split_scan","split_nz":"split_scan","build_fast":"build_frames","aes_nbc":"aes_cfb8","aes_dec_nbc":"aes_cfb8_dec","aes_cfb8_evp":"aes_cfb8","aes_cfb8_evp_dec":"aes_cfb8_dec"}
rows = [("vi_decode","VarInt decode (1M)",0),("vi_encode","VarInt encode (1M)",0),("split_scan","frame split, malloc per body (200k)",0),
        ("split_arena","frame split, arena per body (200k)",0),("split_nz","frame split, non-zeroed malloc (200k)",0),("pos_decode","position decode (200k)",0),("build_frames","build frames (200k), straight port",0),("build_fast","build frames (200k), no per-frame allocation",0),
        ("coro","2000 connection state machines x 100",0),("z_compress","zlib compress 1 MiB L6",1),("z_decompress","zlib decompress 1 MiB",1),
        ("aes_cfb8","AES-CFB8 encrypt, hand-written AES-NI",1),("aes_cfb8_dec","AES-CFB8 decrypt, hand-written AES-NI",1),
        ("aes_nbc","AES-CFB8 encrypt, AES-NI, #no_bounds_check on the proc only",1),("aes_dec_nbc","AES-CFB8 decrypt, AES-NI, #no_bounds_check on the proc only",1),("aes_cfb8_evp","AES-CFB8 encrypt, OpenSSL EVP (FFI)",1),("aes_cfb8_evp_dec","AES-CFB8 decrypt, OpenSSL EVP (FFI)",1)]
print("| benchmark | Rust | Odin -o:speed | Odin / Rust | Odin no checks | no checks / Rust | checks cost |")
print("|---|---|---|---|---|---|---|")
for key, label, br in rows:
    rk = PAIR.get(key, key)
    if rk not in R: continue
    rt = R[rk]; rv = rate(*rt, br)
    ct = C.get(key); ut = U.get(key)
    if not ct: continue
    ratio = rt[0] / ct[0]; uratio = rt[0] / ut[0]
    print(f"| {label} | {rv} | {rate(*ct, br)} | {ratio:.2f}x | {rate(*ut, br)} | {uratio:.2f}x | {ct[0]/ut[0]:.2f}x |")
