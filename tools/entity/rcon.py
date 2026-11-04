#!/usr/bin/env python3
"""Minimal RCON client + per-tick trajectory recorder for a vanilla server.

Freezes the game, steps ONE tick at a time and reads the entity's Pos/Motion/OnGround/Age after each step, so the result is the exact per-tick
state of vanilla's entity physics (doubles as printed by /data).

usage: tools/entity/rcon.py cmd 'any command'
       tools/entity/rcon.py record NAME 'SUMMON_NBT' TICKS [--x X] [--y Y] [--z Z]
          -> $DBCRAFT_CAPTURES/entity_traj_NAME.json (default ~/.cache/dbcraft/captures; never committed: it is data from Mojang's server)
Server: a vanilla copy with enable-rcon=true, rcon.port=25624 (RCON_PORT), rcon.password=entitytest (RCON_PW).  Standard library only.
"""
import json, os, re, socket, struct, sys, time

HOST = "127.0.0.1"
PORT = int(os.environ.get("RCON_PORT", 25624))
PW = os.environ.get("RCON_PW", "entitytest")


class Rcon:
    def __init__(self):
        self.sock = socket.create_connection((HOST, PORT), timeout=float(os.environ.get("RCON_TIMEOUT", 10)))
        self.id = 0
        self._send(3, PW)

    def _read(self, n):
        b = b""
        while len(b) < n:
            c = self.sock.recv(n - len(b))
            if not c:
                raise SystemExit("rcon closed")
            b += c
        return b

    def _send(self, typ, body):
        self.id += 1
        data = struct.pack("<ii", self.id, typ) + body.encode() + b"\0\0"
        self.sock.sendall(struct.pack("<i", len(data)) + data)
        n = struct.unpack("<i", self._read(4))[0]
        resp = self._read(n)
        rid, _ = struct.unpack("<ii", resp[:8])
        if rid == -1:
            raise SystemExit("rcon auth failed")
        return resp[8:-2].decode(errors="replace")

    def cmd(self, c):
        return self._send(2, c)


NUM = r"-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?"


def nums(txt):
    """numbers of the data list in 'X has the following entity data: [1.0d, 2.0d]' (also a bare '5s' / '1b')"""
    tail = txt.split("data:")[-1]
    return [float(x) for x in re.findall("(" + NUM + r")[dDfFbBsSlL]?(?=[,\]\s]|$)", tail)]


def get(r, sel, path):
    return r.cmd(f"data get entity {sel} {path}")


def main():
    r = Rcon()
    if sys.argv[1] == "cmd":
        print(r.cmd(sys.argv[2]))
        return
    name, nbt, ticks = sys.argv[2], sys.argv[3], int(sys.argv[4])
    a = sys.argv[5:]
    x = float(a[a.index("--x") + 1]) if "--x" in a else 0.5
    y = float(a[a.index("--y") + 1]) if "--y" in a else -30.0
    z = float(a[a.index("--z") + 1]) if "--z" in a else 0.5
    r.cmd("tick freeze")
    r.cmd("kill @e[type=item]")
    time.sleep(0.3)
    print(r.cmd(f"summon item {x} {y} {z} {nbt}"))
    sel = "@e[type=item,limit=1,sort=nearest]"
    rows = []
    for t in range(ticks + 1):
        pos = nums(get(r, sel, "Pos"))
        mot = nums(get(r, sel, "Motion"))
        og = "1b" in get(r, sel, "OnGround")
        age = nums(get(r, sel, "Age"))
        rows.append({"tick": t, "pos": pos, "motion": mot, "on_ground": og, "age": age[0] if age else None})
        r.cmd("tick step 1")
        time.sleep(0.12)
    outdir = os.environ.get("DBCRAFT_CAPTURES") or os.path.join(os.environ.get("DBCRAFT_HOME", os.path.expanduser("~/.cache/dbcraft")), "captures")
    os.makedirs(outdir, exist_ok=True)
    json.dump({"name": name, "nbt": nbt, "start": [x, y, z], "rows": rows}, open(os.path.join(outdir, f"entity_traj_{name}.json"), "w"))
    print(name, "recorded", len(rows), "ticks; first", rows[0]["pos"], "last", rows[-1]["pos"], rows[-1]["on_ground"])
    r.cmd("kill @e[type=item]")
    r.cmd("tick unfreeze")


if __name__ == "__main__":
    main()
