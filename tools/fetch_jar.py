#!/usr/bin/env python3
"""Download the pinned official Minecraft server jar from Mojang and verify it.

usage: tools/fetch_jar.py DEST            (DEST = e.g. $DBCRAFT_SERVER_JAR)

The jar is Mojang's and is never committed: it is fetched from Mojang's own launcher metadata at setup time and checked against the SHA-1 and size that
adacraft's pin/26.3.toml records (Minecraft Java 26.3, protocol 777, data version 5023).  Standard library only.  Exit 0 = DEST holds the verified jar.
"""
import hashlib, json, os, sys, urllib.request

VERSION = "26.3"
SHA1 = "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c"
SIZE = 62294556
MANIFEST = "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"


def sha1_of(path):
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def get_json(url):
    with urllib.request.urlopen(url, timeout=60) as r:
        return json.load(r)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    dest = sys.argv[1]
    if os.path.exists(dest) and os.path.getsize(dest) == SIZE and sha1_of(dest) == SHA1:
        print(f"server jar already present and verified: {dest}")
        return
    manifest = get_json(MANIFEST)
    entry = next((v for v in manifest["versions"] if v["id"] == VERSION), None)
    if entry is None:
        sys.exit(f"Minecraft {VERSION} is not in Mojang's version manifest")
    server = get_json(entry["url"])["downloads"]["server"]
    if server["sha1"] != SHA1 or server["size"] != SIZE:
        sys.exit(f"Mojang's metadata for {VERSION} does not match the pin (sha1 {server['sha1']}, size {server['size']}); refusing to continue")
    os.makedirs(os.path.dirname(os.path.abspath(dest)), exist_ok=True)
    tmp = dest + ".part"
    h = hashlib.sha1()
    n = 0
    with urllib.request.urlopen(server["url"], timeout=120) as r, open(tmp, "wb") as out:
        while True:
            chunk = r.read(1 << 20)
            if not chunk:
                break
            out.write(chunk); h.update(chunk); n += len(chunk)
    if n != SIZE or h.hexdigest() != SHA1:
        os.unlink(tmp)
        sys.exit(f"downloaded jar failed verification (size {n}, sha1 {h.hexdigest()}); expected {SIZE} / {SHA1}")
    os.replace(tmp, dest)
    print(f"downloaded and verified {dest} ({n} bytes, sha1 {SHA1})")


main()
