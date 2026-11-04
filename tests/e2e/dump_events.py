import json, sys
# usage: dump.py FILE [hexlen] [skip-names-comma]
path = sys.argv[1]
hl = int(sys.argv[2]) if len(sys.argv) > 2 else 120
skip = set((sys.argv[3] if len(sys.argv) > 3 else "set_time,level_chunk_with_light,light_update,chunk_batch_start,chunk_batch_finished,set_chunk_cache_center,keep_alive").split(","))
def vi(b, o):
    v = s = 0
    while True:
        c = b[o]; o += 1; v |= (c & 0x7f) << s
        if not c & 0x80: return v, o
        s += 7
for l in open(path):
    e = json.loads(l)
    if e["state"] == "mark":
        print("######## MARK", e["name"], "t=%.3f" % e["t"]); continue
    if e["dir"] != "clientbound" or e["state"] != "play": continue
    n = e["name"].replace("minecraft:", "")
    if n in skip: continue
    raw = bytes.fromhex(e["hex"]); _, o = vi(raw, 0); _, o = vi(raw, o)
    print(f'{e["t"]:8.3f} {n:24s} {raw[o:].hex()[:hl]}')
