#!/usr/bin/env python3
"""The big fluid burst, CPU per tick: a 40 x 40 layer of water sources (nine chunk-aligned mc.fill calls) dropped 10 blocks, 120 ticks.

usage: burst.py --port P [--db dbcraft] [--ticks 120] [--size 40] [--drop 10] [--label NAME] [--json OUT]

One transaction per tick, as the server runs them: mc.dyn_step(cur) then mc.broadcast_block_events() on one backend whose CPU time is read from
/proc/PID/schedstat (nanoseconds) around each of the two calls.  A fake connection (a viewer in range) receives the packets.  The fills are executed from other
sessions (an admin's SQL) and are reported separately.  Prints total / worst CPU for dyn_step, the broadcast, and a checksum of the final world and queue
(equal checksums = equal result), so that two implementations of the engine can be compared (see also tests/sql/880: mc.dyn_run_seq equivalence).
"""
import argparse, hashlib, json, os, sys, time
import psycopg2


def cpu_ns(pid):
    with open("/proc/%d/schedstat" % pid) as f:
        return int(f.read().split()[0])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True); ap.add_argument("--db", default="dbcraft")
    ap.add_argument("--ticks", type=int, default=120); ap.add_argument("--size", type=int, default=40); ap.add_argument("--drop", type=int, default=10)
    ap.add_argument("--label", default=""); ap.add_argument("--json"); ap.add_argument("--seq", action="store_true", help="use the sequential engine (mc.dyn_batch = off)")
    ap.add_argument("--set", action="append", default=[], help="key=value server_property")
    a = ap.parse_args()
    dsn = "host=/tmp port=%d user=postgres dbname=%s" % (a.port, a.db)
    adm = psycopg2.connect(dsn); adm.autocommit = True; ac = adm.cursor()
    for kv in a.set:
        k, v = kv.split("=", 1)
        ac.execute("update mc.server_property set value = %s where key = %s", (v, k))
    ac.execute("truncate net.conn, mc.play_out, mc.block_event, mc.block_tick, mc.dyn_late_event; delete from mc.player")
    ac.execute("insert into net.conn (conn_id, state, compression, closing, view_cx, view_cz) values (1, 'play', -1, false, 1, 1)")
    ac.execute("insert into mc.player (uuid, name, conn_id, entity_id, chunk_x, chunk_z) values ('00000000-0000-0000-0000-00000000d001', 'Dyn', 1, 1, 1, 1)")
    ac.execute("insert into mc.game_rule (name, value) values ('minecraft:random_tick_speed', '0') on conflict (name) do update set value = '0'")
    ac.execute("select mc.generate_flat_area('minecraft:overworld', -3, -3, 7, 7)")
    ac.execute("select mc.fill('minecraft:overworld', -40, -61, -40, 100, -61, 100, 'minecraft:grass_block[snowy=false]')")
    ac.execute("select mc.fill('minecraft:overworld', -40, -60, -40, 100, -40, 100, 'minecraft:air')")
    ac.execute("truncate mc.block_tick, mc.block_event, mc.play_out, mc.dyn_late_event")
    ac.execute("select game_time from mc.game_state"); gt = ac.fetchone()[0]
    y = -61 + a.drop
    t0 = time.time(); fills = 0
    for cx in range(0, a.size, 16):
        for cz in range(0, a.size, 16):
            ac.execute("select mc.fill('minecraft:overworld', %s, %s, %s, %s, %s, %s, 'minecraft:water')", (cx, y, cz, min(cx + 15, a.size - 1), y, min(cz + 15, a.size - 1)))
            fills += 1
    fill_ms = (time.time() - t0) * 1000
    ac.execute("select count(*) from mc.block_tick"); queued = ac.fetchone()[0]
    c = psycopg2.connect(dsn); c.autocommit = False; cur = c.cursor()
    cur.execute("select pg_backend_pid()"); pid = cur.fetchone()[0]; c.commit()
    # warm-up of the plan caches and the function bodies on a quiet tick, so that the first burst tick does not pay for compilation
    cur.execute("select mc.dyn_step(%s)", (gt,)); c.commit()
    step_cpu = []; bc_cpu = []; n_packets = 0
    for i in range(a.ticks):
        cur.execute("update mc.game_state set game_time = game_time + 1 returning game_time"); g = cur.fetchone()[0]
        t = cpu_ns(pid); cur.execute("select mc.dyn_step(%s)", (g,)); t1 = cpu_ns(pid)
        cur.execute("select mc.broadcast_block_events()"); t2 = cpu_ns(pid)
        c.commit()
        step_cpu.append((t1 - t) / 1e6); bc_cpu.append((t2 - t1) / 1e6)
    cur.execute("select count(*) from mc.play_out"); n_packets = cur.fetchone()[0]
    cur.execute("select count(*) from mc.error_log where step = 'dyn_step'"); errs = cur.fetchone()[0]
    ac.execute("select mc.get_block('minecraft:overworld', x, y, z) from generate_series(-12, %s) x, generate_series(-61, %s) y, generate_series(-12, %s) z order by x, y, z" % (a.size + 12, y, a.size + 12))
    h = hashlib.md5()
    water = 0
    for (b,) in ac.fetchall():
        h.update(b.encode())
        water += b.startswith("minecraft:water")
    ac.execute("select count(*), coalesce(sum(due), 0)::bigint from mc.block_tick"); q = ac.fetchone()
    ac.execute("select coalesce(md5(string_agg(data, ''::bytea order by seq))::text, '') from (select seq, data from mc.play_out where conn_id = 1 order by seq) s"); pk = ac.fetchone()[0]
    import re as _re
    notes = [n for n in c.notices if "dynprof" in n or "runprof" in n]
    if notes:
        import re as _r
        tot = {}
        for n in notes:
            for k, v in _r.findall(r"(\w+)=(\d+)", n):
                tot[k] = tot.get(k, 0) + int(v)
        print("dyn_run phases (ms, summed over %d calls): %s" % (len(notes), tot))
    res = dict(label=a.label, ticks=a.ticks, fill_ms=round(fill_ms, 1), queued_after_fills=queued,
               step_total_ms=round(sum(step_cpu), 1), step_worst_ms=round(max(step_cpu), 1), bc_total_ms=round(sum(bc_cpu), 1), bc_worst_ms=round(max(bc_cpu), 1),
               total_ms=round(sum(step_cpu) + sum(bc_cpu), 1), worst_tick_ms=round(max(s + b for s, b in zip(step_cpu, bc_cpu)), 1),
               ticks_over_60ms=sum(1 for s, b in zip(step_cpu, bc_cpu) if s + b > 60), water_cells=water, world_md5=h.hexdigest(), queue=list(q), packets_md5=pk, packet_rows=n_packets, errors=errs,
               per_tick=[round(s + b, 1) for s, b in zip(step_cpu, bc_cpu)])
    print(json.dumps({k: v for k, v in res.items() if k != "per_tick"}))
    if a.json:
        json.dump(res, open(a.json, "w"))


main()
