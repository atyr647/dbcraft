#!/usr/bin/env python3
"""Download the official Minecraft Java client (and everything it needs to start) from Mojang's launcher metadata, verifying every SHA-1.

usage: python3 -I tools/realclient/download_client.py [VERSION=26.3] [DEST=/tmp/mc-client]
Writes DEST/client.jar, DEST/libraries/**, DEST/assets/{indexes,objects,log_configs}, DEST/version.json, DEST/launch.json (class path + metadata).
Nothing here is committed: it is Mojang's data.  Standard library only; run with -I so no downloaded file can shadow a module.
"""
import hashlib, json, os, sys, urllib.request, concurrent.futures as cf

ver = sys.argv[1] if len(sys.argv) > 1 else "26.3"
dest = sys.argv[2] if len(sys.argv) > 2 else "/tmp/mc-client"
os.makedirs(dest, exist_ok=True)


def get(url):
    with urllib.request.urlopen(url, timeout=60) as r:
        return r.read()


def fetch(url, path, sha1=None):
    if os.path.exists(path) and (sha1 is None or hashlib.sha1(open(path, "rb").read()).hexdigest() == sha1):
        return 0
    os.makedirs(os.path.dirname(path), exist_ok=True)
    data = get(url)
    if sha1 and hashlib.sha1(data).hexdigest() != sha1:
        raise SystemExit(f"SHA-1 mismatch for {url}")
    open(path + ".part", "wb").write(data)
    os.replace(path + ".part", path)
    return len(data)


manifest = json.loads(get("https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"))
entry = next(v for v in manifest["versions"] if v["id"] == ver)
meta_bytes = get(entry["url"])
assert hashlib.sha1(meta_bytes).hexdigest() == entry["sha1"], "version json hash mismatch"
meta = json.loads(meta_bytes)
json.dump(meta, open(os.path.join(dest, "version.json"), "w"), indent=1)


def allowed(rules):
    if not rules:
        return True
    ok = False
    for r in rules:
        osr = r.get("os")
        match = True
        if osr:
            if "name" in osr and osr["name"] != "linux":
                match = False
            if "arch" in osr and osr["arch"] not in ("x86_64", "amd64"):
                match = False
        if "features" in r:
            match = False  # demo / custom resolution features are off
        if match:
            ok = r["action"] == "allow"
    return ok


jobs = [(meta["downloads"]["client"]["url"], os.path.join(dest, "client.jar"), meta["downloads"]["client"]["sha1"])]
cp = []
for lib in meta["libraries"]:
    if not allowed(lib.get("rules")):
        continue
    a = lib["downloads"].get("artifact")
    if a:
        p = os.path.join(dest, "libraries", a["path"])
        jobs.append((a["url"], p, a["sha1"]))
        cp.append(p)
idx = meta["assetIndex"]
idx_path = os.path.join(dest, "assets", "indexes", idx["id"] + ".json")
fetch(idx["url"], idx_path, idx["sha1"])
index = json.load(open(idx_path))
for name, o in index["objects"].items():
    h = o["hash"]
    jobs.append((f"https://resources.download.minecraft.net/{h[:2]}/{h}", os.path.join(dest, "assets", "objects", h[:2], h), h))
if "logging" in meta and "client" in meta["logging"]:
    f = meta["logging"]["client"]["file"]
    jobs.append((f["url"], os.path.join(dest, "assets", "log_configs", f["id"]), f["sha1"]))

total = 0
with cf.ThreadPoolExecutor(16) as ex:
    futs = [ex.submit(fetch, *j) for j in jobs]
    for i, f in enumerate(cf.as_completed(futs)):
        total += f.result()
        if i % 500 == 0:
            print(f"{i}/{len(jobs)} files", flush=True)
cp.append(os.path.join(dest, "client.jar"))
json.dump({"main": meta["mainClass"], "classpath": cp, "assetIndex": idx["id"], "arguments": meta.get("arguments"),
           "java": meta.get("javaVersion"), "logging": meta.get("logging", {}).get("client")},
          open(os.path.join(dest, "launch.json"), "w"), indent=1)
print(f"downloaded {total/1e6:.1f} MB in {len(jobs)} files, all SHA-1 verified; main class {meta['mainClass']}, java {meta.get('javaVersion')}")
