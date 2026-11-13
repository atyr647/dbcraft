#!/usr/bin/env python3
"""Random-tick rates, vanilla against dbcraft: the statistics of the block families that grow, spread or decay by random ticks (sugar cane, cactus, leaves).

Random ticks are not byte-comparable (vanilla draws its own random numbers), so both servers run the same set-up for the same number of ticks at the default random_tick_speed 3 and the
distribution of the outcomes is compared: vanilla through RCON (`/tick sprint`), dbcraft through SQL (mc.dyn_step in a loop, one transaction per tick).

usage:
  rt_rate.py vanilla --port P --rcon R [--rcon-pw dbcraft-e2e] --out v.json [--ticks N] [--only cane,cactus,leaves]
  rt_rate.py dbcraft --psql 'psql -X -At -h /tmp -p PORT -U postgres DB' --out d.json [--ticks N] [--only ...]
  rt_rate.py compare v.json d.json

Plots (every one isolated from the others): a sugar cane (age 0) on grass with a water source beside the grass block (the water in a hole of the floor so that it stays put), 100 of them;
a cactus (age 0) on sand, 100; leaves (distance 7, not persistent: they decay) 200 in a layer.  After the ticks: cane: fraction that grew a second block, histogram of ages;
cactus: fraction that grew, fraction that flowered, histogram of ages; leaves: fraction that survived.  A rate is `ok` when the two servers' fractions differ by less than
three standard errors of their difference.
"""
import argparse, json, math, os, re, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools", "scoreboard"))

N_CANE, N_CACTUS, N_LEAVES = 100, 100, 200


def plots(kind):
    """(x, y, z) of the plant (cane / cactus) or leaf of every plot"""
    if kind == "cane":
        return [(-30 + 3 * (i % 20), -60, 3 + 3 * (i // 20)) for i in range(N_CANE)]
    if kind == "cactus":
        return [(-30 + 3 * (i % 20), -60, 20 + 3 * (i // 20)) for i in range(N_CACTUS)]
    return [(-20 + (i % 20), -60, -20 - (i // 20)) for i in range(N_LEAVES)]


def vanilla_ops(kind):
    ops = []
    if kind == "cane":
        for (x, y, z) in plots("cane"):
            ops += ["setblock %d %d %d minecraft:water" % (x + 1, y - 1, z), "setblock %d %d %d minecraft:sugar_cane[age=0]" % (x, y, z)]
    elif kind == "cactus":
        for (x, y, z) in plots("cactus"):
            ops += ["setblock %d %d %d minecraft:sand" % (x, y - 1, z), "setblock %d %d %d minecraft:cactus[age=0]" % (x, y, z)]
    else:
        for (x, y, z) in plots("leaves"):
            ops += ["setblock %d %d %d minecraft:oak_leaves[distance=7,persistent=false]" % (x, y, z)]
    return ops


def run_vanilla(a):
    import mcclient as m
    import common as C
    rc = C.Rcon(port=a.rcon, pw=a.rcon_pw)
    c = m.Client("127.0.0.1", a.port, "Dyn")
    rc.cmd("tp Dyn 0 -60 0"); rc.cmd("gamerule random_tick_speed 3"); rc.cmd("gamerule spawn_mobs false"); rc.cmd("tick unfreeze")
    c.settle(1.0, 15.0)
    res = {}
    for kind in a.only.split(","):
        rc.cmd("fill -34 -62 -26 34 -62 70 minecraft:dirt"); rc.cmd("fill -34 -61 -26 34 -61 70 minecraft:grass_block"); rc.cmd("fill -34 -60 -26 34 -50 70 minecraft:air")
        time.sleep(2.0)
        for op in vanilla_ops(kind):
            rc.cmd(op)
        time.sleep(1.0)
        rc.cmd("tick sprint %d" % a.ticks)
        t0 = time.time()
        while time.time() - t0 < 900 and "sprinting" in rc.cmd("tick query").lower():
            time.sleep(1.0)
        time.sleep(1.0)
        res[kind] = measure_vanilla(rc, kind)
        print(kind, res[kind])
    c.close()
    json.dump(res, open(a.out, "w"))


def measure_vanilla(rc, kind):
    def has(x, y, z, b):
        return "passed" in rc.cmd("execute if block %d %d %d %s" % (x, y, z, b)).lower()
    out = {"ticks": None}
    if kind in ("cane", "cactus"):
        blk = "minecraft:sugar_cane" if kind == "cane" else "minecraft:cactus"
        ages = [0] * 16; grown = 0; flowered = 0
        for (x, y, z) in plots(kind):
            if has(x, y + 1, z, blk):
                grown += 1
            if kind == "cactus" and has(x, y + 1, z, "minecraft:cactus_flower"):
                flowered += 1
            for g in range(16):
                if has(x, y, z, "%s[age=%d]" % (blk, g)):
                    ages[g] += 1; break
        out.update(n=len(plots(kind)), grown=grown, flowered=flowered, ages=ages)
    else:
        alive = sum(1 for (x, y, z) in plots("leaves") if has(x, y, z, "minecraft:oak_leaves"))
        out.update(n=N_LEAVES, alive=alive)
    return out


def run_dbcraft(a):
    psql = a.psql.split()

    def sql(q):
        r = subprocess.run(psql + ["-c", q], capture_output=True, text=True)
        if r.returncode:
            raise SystemExit(r.stderr)
        return r.stdout

    sql("truncate net.conn, mc.play_out, mc.block_event, mc.block_tick; delete from mc.player; "
        "insert into net.conn (conn_id, state, compression, closing, view_cx, view_cz) values (1, 'play', -1, false, 0, 0); "
        "insert into mc.player (uuid, name, conn_id, entity_id, chunk_x, chunk_z) values ('00000000-0000-0000-0000-00000000d001', 'Dyn', 1, 1, 0, 0); "
        "insert into mc.game_rule (name, value) values ('minecraft:random_tick_speed', '3') on conflict (name) do update set value = '3'; "
        "update mc.server_property set value = '0' where key = 'dbcraft.dynamics-tick-budget-ms'; update mc.server_property set value = '4' where key = 'simulation-distance'; "
        "update mc.server_property set value = '4' where key = 'dbcraft.random-tick-interval'")
    sql("select mc.generate_flat_area('minecraft:overworld', -3, -3, 3, 5)")
    res = {}
    for kind in a.only.split(","):
        sql("select mc.fill('minecraft:overworld', -34, -62, -26, 34, -62, 70, 'minecraft:dirt'); select mc.fill('minecraft:overworld', -34, -61, -26, 34, -61, 70, 'minecraft:grass_block[snowy=false]'); "
            "select mc.fill('minecraft:overworld', -34, -60, -26, 34, -50, 70, 'minecraft:air'); truncate mc.block_tick, mc.block_event; delete from mc.dyn_rt_dirty")
        stm = []
        if kind == "cane":
            for (x, y, z) in plots("cane"):
                stm += ["select mc.set_block('minecraft:overworld', %d, %d, %d, 'minecraft:water')" % (x + 1, y - 1, z), "select mc.set_block('minecraft:overworld', %d, %d, %d, 'minecraft:sugar_cane[age=0]')" % (x, y, z)]
        elif kind == "cactus":
            for (x, y, z) in plots("cactus"):
                stm += ["select mc.set_block('minecraft:overworld', %d, %d, %d, 'minecraft:sand')" % (x, y - 1, z), "select mc.set_block('minecraft:overworld', %d, %d, %d, 'minecraft:cactus[age=0]')" % (x, y, z)]
        else:
            for (x, y, z) in plots("leaves"):
                stm += ["select mc.set_block('minecraft:overworld', %d, %d, %d, 'minecraft:oak_leaves[distance=7,persistent=false,waterlogged=false]')" % (x, y, z)]
        sql("; ".join(stm))
        # (a rebuild of the lists is queued by the edits or patched; the quiet period of the maintenance is skipped by running the queued builds at once)
        sql("update mc.server_property set value = '0' where key = 'dbcraft.random-tick-quiet'; update mc.server_property set value = '100000' where key = 'dbcraft.random-tick-build-ms'")
        n = a.ticks
        t0 = time.time()
        step = 2000
        for i in range(0, n, step):
            sql("do $$ declare cur bigint; i int; begin for i in 1 .. %d loop update mc.game_state set game_time = game_time + 1, day_time = 6000 returning game_time into cur; perform mc.dyn_step(cur); delete from mc.block_event; end loop; end $$" % min(step, n - i))
        res[kind] = measure_dbcraft(sql, kind)
        res[kind]["wall_s"] = round(time.time() - t0, 1)
        print(kind, res[kind])
    json.dump(res, open(a.out, "w"))


def measure_dbcraft(sql, kind):
    def blocks(kindname):
        out = sql("select x || ',' || y || ',' || z || ',' || block from mc.blocks_in('minecraft:overworld', -34, -60, -40, 34, -58, 70) where block like 'minecraft:%s%%'" % kindname)
        return [l.split(",", 3) for l in out.split("\n") if l]
    out = {}
    if kind in ("cane", "cactus"):
        blk = "sugar_cane" if kind == "cane" else "cactus"
        have = {(int(p[0]), int(p[1]), int(p[2])): p[3] for p in blocks(blk)}
        ages = [0] * 16; grown = 0; flowered = 0
        fl = {(int(p[0]), int(p[1]), int(p[2])) for p in blocks("cactus_flower")} if kind == "cactus" else set()
        for (x, y, z) in plots(kind):
            if (x, y + 1, z) in have:
                grown += 1
            if (x, y + 1, z) in fl:
                flowered += 1
            nm = have.get((x, y, z))
            if nm:
                ages[int(re.search(r"age=(\d+)", nm).group(1))] += 1
        out.update(n=len(plots(kind)), grown=grown, flowered=flowered, ages=ages)
    else:
        have = {(int(p[0]), int(p[1]), int(p[2])) for p in blocks("oak_leaves")}
        out.update(n=N_LEAVES, alive=sum(1 for p in plots("leaves") if p in have))
    return out


def compare(a):
    v = json.load(open(a.files[0])); d = json.load(open(a.files[1]))
    bad = 0

    def z(k1, n1, k2, n2):
        p1, p2 = k1 / n1, k2 / n2
        p = (k1 + k2) / (n1 + n2)
        se = math.sqrt(max(p * (1 - p), 1e-9) * (1 / n1 + 1 / n2))
        return p1, p2, (p1 - p2) / se

    for kind in v:
        if kind not in d:
            continue
        a_, b_ = v[kind], d[kind]
        for key in ("grown", "flowered", "alive"):
            if key in a_:
                p1, p2, zz = z(a_[key], a_["n"], b_[key], b_["n"])
                ok = abs(zz) < 3
                bad += 0 if ok else 1
                print("%-7s %-8s vanilla %.3f  dbcraft %.3f  z = %+.2f  %s" % (kind, key, p1, p2, zz, "ok" if ok else "DIFFERENT"))
        if "ages" in a_:
            ma = sum(i * c for i, c in enumerate(a_["ages"])) / max(1, sum(a_["ages"])); mb = sum(i * c for i, c in enumerate(b_["ages"])) / max(1, sum(b_["ages"]))
            print("%-7s mean age vanilla %.2f dbcraft %.2f" % (kind, ma, mb))
    print("ALL RATES AGREE (within 3 standard errors)" if not bad else "%d rate(s) differ" % bad)
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["vanilla", "dbcraft", "compare"]); ap.add_argument("files", nargs="*")
    ap.add_argument("--port", type=int, default=25931); ap.add_argument("--rcon", type=int, default=25935); ap.add_argument("--rcon-pw", default="dbcraft-e2e")
    ap.add_argument("--psql"); ap.add_argument("--out"); ap.add_argument("--ticks", type=int, default=21000); ap.add_argument("--only", default="cane,cactus,leaves")
    a = ap.parse_args()
    if a.mode == "vanilla":
        run_vanilla(a)
    elif a.mode == "dbcraft":
        run_dbcraft(a)
    else:
        sys.exit(compare(a))


main()
