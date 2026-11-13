#!/usr/bin/env python3
"""Cold against warm fills: CPU of the filling statement and of the broadcast (the tick) for a fill the template cache (mc.sbu_tpl) has never seen, then the same box again.

usage: cold_fill.py --port P [--db dbcraft] [--reps 5] [--json OUT]

One fake connection in range.  Scenarios: 1,000 blocks (10 x 10 x 10, unaligned), 100,000 blocks (46 x 46 x 47, unaligned: 27 distinct section shapes), 262,144 (64 whole sections).
For each rep: the template cache is emptied (cold), the box is filled with stone (cold statement + broadcast tick), then with air (warm), then stone again (warm).  CPU time of the
backend from /proc/PID/schedstat (nanoseconds).  Prints the median over the reps.
"""
import argparse, json, statistics, sys
import psycopg2


def cpu_ns(pid):
    with open("/proc/%d/schedstat" % pid) as f:
        return int(f.read().split()[0])


SCEN = {"1000": (3, -60, 5, 12, -51, 14), "100000": (3, -60, 5, 48, -14, 51), "64_sections": (0, -64, 0, 63, -1, 63)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True); ap.add_argument("--db", default="dbcraft"); ap.add_argument("--reps", type=int, default=5); ap.add_argument("--json")
    ap.add_argument("--only")
    a = ap.parse_args()
    dsn = "host=/tmp port=%d user=postgres dbname=%s" % (a.port, a.db)
    admin = psycopg2.connect(dsn); admin.autocommit = True; ac = admin.cursor()
    ac.execute("truncate net.conn, mc.play_out, mc.block_event, mc.block_tick; delete from mc.player")
    ac.execute("insert into net.conn (conn_id, state, compression, closing, view_cx, view_cz) values (1, 'play', -1, false, 2, 2)")
    ac.execute("insert into mc.player (uuid, name, conn_id, entity_id, chunk_x, chunk_z) values ('00000000-0000-0000-0000-00000000d001', 'Dyn', 1, 1, 2, 2)")
    ac.execute("update mc.server_property set value = '6' where key = 'view-distance'")
    ac.execute("select mc.generate_flat_area('minecraft:overworld', -1, -1, 6, 6)")
    ac.execute("select mc.pid('block_update')")
    fillc = psycopg2.connect(dsn); fillc.autocommit = True; fc = fillc.cursor(); fc.execute("select pg_backend_pid()"); fpid = fc.fetchone()[0]
    tickc = psycopg2.connect(dsn); tickc.autocommit = False; tc = tickc.cursor(); tc.execute("select pg_backend_pid()"); tpid = tc.fetchone()[0]; tickc.commit()
    out = {}
    for name, box in SCEN.items():
        if a.only and name != a.only:
            continue
        rows = {"cold": [], "warm_air": [], "warm_stone": []}
        for _ in range(a.reps):
            ac.execute("truncate mc.sbu_tpl")
            ac.execute("select mc.fill('minecraft:overworld', %s, %s, %s, %s, %s, %s, 'minecraft:air')", box)
            ac.execute("delete from mc.block_event; truncate mc.play_out"); ac.execute("truncate mc.sbu_tpl")
            for label, blk in (("cold", "stone"), ("warm_air", "air"), ("warm_stone", "stone")):
                t = cpu_ns(fpid)
                fc.execute("select mc.fill('minecraft:overworld', %s, %s, %s, %s, %s, %s, %s)", (*box, "minecraft:" + blk))
                t1 = cpu_ns(fpid)
                ta = cpu_ns(tpid)
                tc.execute("select mc.broadcast_block_events()"); tickc.commit()
                tb = cpu_ns(tpid)
                rows[label].append(((t1 - t) / 1e6, (tb - ta) / 1e6))
                ac.execute("truncate mc.play_out")
        out[name] = {k: [statistics.median(v[0] for v in vs), statistics.median(v[1] for v in vs)] for k, vs in rows.items()}
        print(name, {k: [round(x, 1) for x in v] for k, v in out[name].items()}, "(statement ms, tick ms) CPU, median of", a.reps)
    if a.json:
        json.dump(out, open(a.json, "w"))


main()
