#!/usr/bin/env python3
"""A furnace as one client sees it: the REAL vanilla 26.3 server and dbcraft each run the same scenario for a scripted client and the container packets (open, slot updates,
the four ContainerData values every tick) are compared in order.  Wall-clock timing differs between two servers, so the comparison is of the SEQUENCE: both streams are cut at
the first container_set_data that shows fuel burning, and compared packet by packet over the common length.

usage:
  record:   furnace_probe.py record --mode vanilla --port 25881 --rcon 25885 --kind furnace --out v.json
            furnace_probe.py record --mode dbcraft --port 25887 --psql 'psql -X -At -h /tmp -p 55467 -U postgres dbcraft' --kind furnace --out o.json
  compare:  furnace_probe.py compare v.json o.json
Scenario: an empty furnace of the kind is opened; then (two commands) the input stack and the fuel are put in over RCON / SQL; the client listens for --seconds.
"""
import argparse, json, os, struct, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools", "scoreboard"))
import mcclient as m

ITEM_NAME = {v: k for k, v in m.ITEM.items()}
KINDS = {"furnace": "minecraft:furnace", "blast": "minecraft:blast_furnace", "smoker": "minecraft:smoker"}
POS = (2, -60, 0)


def pv(b, o):
    return m.parse_varint(b, o)


def stack(b, o):
    n, o = pv(b, o)
    if n == 0:
        return None, o
    iid, o = pv(b, o); a, o = pv(b, o); r, o = pv(b, o)
    return [ITEM_NAME[iid].replace("minecraft:", ""), n], o


def reduce(e):
    nm = e["name"].replace("minecraft:", ""); b = e["body"]
    if nm == "container_set_slot":
        cid, o = pv(b, 0); st, o = pv(b, o); slot = struct.unpack(">h", b[o:o + 2])[0]; s, o = stack(b, o + 2)
        return ["set_slot", cid, slot, s, st]
    if nm == "container_set_content":
        cid, o = pv(b, 0); st, o = pv(b, o); n, o = pv(b, o); items = []
        for _ in range(n):
            s, o = stack(b, o); items.append(s)
        return ["set_content", cid, st, [i for i in items[:3]]]
    if nm == "container_set_data":
        cid, o = pv(b, 0); i, v = struct.unpack(">hh", b[o:o + 4]); return ["data", cid, i, v]
    if nm == "open_screen":
        cid, o = pv(b, 0); t, o = pv(b, o); return ["open", cid, t]
    if nm == "block_update":
        return ["block_update", list(m.unposition(b, 0)), pv(b, 8)[0]]
    return None


def record(a):
    rc = None
    if a.mode == "vanilla":
        import common as C
        rc = C.Rcon(port=a.rcon, pw=a.rcon_pw)
        rc.cmd("op Cont"); rc.cmd("kill @e[type=item]")
    else:
        sql(a, "delete from mc.inventory_slot where player in (select uuid from mc.player where name = 'Cont')")
        sql(a, "delete from mc.menu_state where player in (select uuid from mc.player where name = 'Cont')")
    c = m.Client("127.0.0.1", a.port, "Cont")
    c.settle(1.0, 15.0)
    if a.mode == "dbcraft":
        sql(a, "insert into mc.op (uuid, name, level) select uuid, name, 4 from mc.player where name = 'Cont' on conflict do nothing")
    c.send("minecraft:chat_command", m.string("gamemode survival")); time.sleep(0.4)
    c.send("minecraft:chat_command", m.string("tp Cont 0.5 -60 0.5")); time.sleep(0.5)
    x, y, z = POS
    if a.mode == "vanilla":
        rc.cmd(f"setblock {x} {y} {z} minecraft:air"); rc.cmd(f"setblock {x} {y} {z} {KINDS[a.kind]}")
        # a furnace that stays lit from an earlier run would start differently: the setblock gives a fresh block entity
    else:
        sql(a, "delete from mc.container_slot; delete from mc.furnace")
        sql(a, f"select mc.set_block('minecraft:overworld', {x}, {y}, {z}, 'minecraft:air')")
        sql(a, f"select mc.set_block('minecraft:overworld', {x}, {y}, {z}, '{KINDS[a.kind]}')")
    time.sleep(0.6)
    k = c.count()
    c.send("minecraft:use_item_on", m.varint(0) + m.position(x, y, z) + m.varint(1) + struct.pack(">fff", 0.5, 1.0, 0.5) + b"\x00\x00" + m.varint(1))
    time.sleep(0.5)
    t0 = time.time()
    if a.mode == "vanilla":
        rc.cmd(f"item replace block {x} {y} {z} container.0 with {a.input} {a.count}")
        rc.cmd(f"item replace block {x} {y} {z} container.1 with {a.fuel} {a.fuel_count}")
    else:
        sql(a, f"insert into mc.container_slot values ('minecraft:overworld', {x}, {y}, {z}, 0, '{a.input}', {a.count}, null), ('minecraft:overworld', {x}, {y}, {z}, 1, '{a.fuel}', {a.fuel_count}, null)")
    time.sleep(a.seconds)
    out = []
    for e in c.since(k):
        if e["name"].replace("minecraft:", "") in ("container_set_slot", "container_set_content", "container_set_data", "open_screen", "block_update"):
            r = reduce(e)
            if r:
                out.append(r)
    json.dump({"kind": a.kind, "packets": out}, open(a.out, "w"))
    print(f"recorded {len(out)} packets")
    c.close()


def sql(a, q):
    r = subprocess.run(a.psql.split() + ["-c", q], capture_output=True, text=True)
    if r.returncode:
        print("SQL ERROR", r.stderr)


def compare(path_a, path_b):
    A, B = json.load(open(path_a))["packets"], json.load(open(path_b))["packets"]
    def head(P):
        i = next((k for k, p in enumerate(P) if p[0] == "data" and p[2] == 0 and p[3] > 0), None)
        return P[:i] if i is not None else P, P[i:] if i is not None else []
    ha, ta = head(A); hb, tb = head(B)
    # the packets before the fuel burns: the opening (open, content, 4 data) and the two slot updates; the slot update that carries the state id is compared without it (two commands
    # may land in different ticks, which changes nothing but the order of equal packets)
    ok = True
    def norm(P):
        return [p for p in P if p[0] != "block_update"]
    print("before the fuel burns:\n  vanilla", norm(ha), "\n  ours   ", norm(hb))
    ta, tb = norm(ta), norm(tb)           # (a block_update far away is vanilla's world noise: it does not belong to the furnace stream)
    n = min(len(ta), len(tb))
    bad = [(i, ta[i], tb[i]) for i in range(n) if ta[i] != tb[i]]
    print(f"after: {len(ta)} vanilla packets, {len(tb)} ours, {n} compared, {len(bad)} differ")
    for b in bad[:8]:
        print("  ", b)
    if norm(ha)[:6] != norm(hb)[:6]:
        ok = False
    ok = ok and not bad and n > 40
    print("OK" if ok else "FAIL")
    sys.exit(0 if ok else 1)


ap = argparse.ArgumentParser()
sub = ap.add_subparsers(dest="cmd", required=True)
r = sub.add_parser("record")
r.add_argument("--mode", choices=["vanilla", "dbcraft"], required=True); r.add_argument("--port", type=int, required=True)
r.add_argument("--rcon", type=int); r.add_argument("--rcon-pw", default="dbcraft-cont"); r.add_argument("--psql")
r.add_argument("--kind", choices=list(KINDS), default="furnace"); r.add_argument("--input", default="minecraft:raw_iron"); r.add_argument("--count", type=int, default=3)
r.add_argument("--fuel", default="minecraft:coal"); r.add_argument("--fuel-count", type=int, default=2); r.add_argument("--seconds", type=float, default=14)
r.add_argument("--out", required=True)
c = sub.add_parser("compare"); c.add_argument("a"); c.add_argument("b")
args = ap.parse_args()
if args.cmd == "record":
    record(args)
else:
    compare(args.a, args.b)
