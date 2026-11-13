#!/usr/bin/env python3
"""Equivalence of two builds of the dynamics engine on random scenarios: the same ops are run in two databases (typically a clone made before a change and the changed one),
tick by tick, and after EVERY tick the packets a viewer receives and the scheduled-tick queue are hashed and compared; at the end the world around the scenario is hashed.

usage: dyn_equiv.py --port P --a DB_A --b DB_B [--seeds 1,2,3] [--ops 40] [--max-step 25] [--lava] [--set key=value ...]

Leaves, sugar cane and cactus are not in the block pool: the starting commit did not model them, so a comparison against it would differ by design.
A scenario (seed): fills and single blocks of water, optionally lava, and of obstacles of every shape class (full blocks, slabs, stairs, fences, trapdoors, sand, gravel, concrete powder, torches,
flowers, ladders, signs, waterlogged blocks, farmland with crops, glass), holes in the floor, in a region spanning four chunks, interleaved with runs of ticks.  The random() calls of the
engine (lava delay) are made reproducible with setseed on the stepping connection.  Exit status 1 when any tick differs.
"""
import argparse, hashlib, random, sys
import psycopg2

BLOCKS = ["stone", "oak_slab[type=bottom,waterlogged=false]", "oak_slab[type=top,waterlogged=false]", "oak_stairs[facing=north,half=bottom,shape=straight,waterlogged=false]",
          "oak_fence[east=false,north=false,south=false,waterlogged=false,west=false]", "oak_trapdoor[facing=north,half=bottom,open=false,powered=false,waterlogged=false]",
          "sand", "gravel", "red_concrete_powder", "torch", "poppy", "short_grass", "glass", "dirt", "cobblestone", "farmland[moisture=0]", "wheat[age=0]",
          "ladder[facing=south,waterlogged=false]", "white_carpet", "oak_sign[rotation=0,waterlogged=false]", "iron_bars[east=false,north=false,south=false,waterlogged=false,west=false]",
          "kelp[age=0]", "seagrass", "tall_grass[half=lower]", "snow[layers=1]", "stone_slab[type=double,waterlogged=false]"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True); ap.add_argument("--a", required=True); ap.add_argument("--b", required=True)
    ap.add_argument("--seeds", default="1,2,3"); ap.add_argument("--ops", type=int, default=40); ap.add_argument("--max-step", type=int, default=25)
    ap.add_argument("--lava", action="store_true"); ap.add_argument("--set", action="append", default=[])
    ap.add_argument("--region", type=int, default=24)
    a = ap.parse_args()
    bad = 0
    for seed in [int(s) for s in a.seeds.split(",")]:
        rng = random.Random(seed)
        ops = gen(rng, a)
        results = []
        for db in (a.a, a.b):
            results.append(run(a, db, ops))
        ra, rb = results
        diffs = [i for i, (x, y) in enumerate(zip(ra["ticks"], rb["ticks"])) if x != y]
        same_end = ra["world"] == rb["world"]
        print("seed %d: %d ops, %d ticks, packets %d: %s%s" % (seed, len(ops), len(ra["ticks"]), ra["npk"],
              "IDENTICAL" if not diffs and same_end else "DIFFERENT at ticks %s" % diffs[:10], "" if same_end else " (world differs)"))
        if diffs or not same_end:
            bad += 1
            if diffs:
                i = diffs[0]
                print("  first differing tick %d: A %d packets, B %d packets" % (i, len(ra["raw"][i]), len(rb["raw"][i])))
                qa = ra["qraw"][i].split(" ; "); qb = rb["qraw"][i].split(" ; ")
                print("   queue A %d rows, B %d rows; first differing rows:" % (len(qa), len(qb)))
                for j, (xa, xb) in enumerate(zip(qa, qb)):
                    if xa != xb:
                        print("    row", j, "A", xa, "B", xb); break
                print("    only in A:", sorted(set(qa) - set(qb))[:4], "only in B:", sorted(set(qb) - set(qa))[:4])
                for j, (xa, xb) in enumerate(zip(ra["raw"][i], rb["raw"][i])):
                    if xa != xb:
                        print("   packet", j, "differs:\n    A", xa[:400], "\n    B", xb[:400]); break
    sys.exit(1 if bad else 0)


def gen(rng, a):
    R = a.region
    ops = []
    ops.append(("sql", "select mc.fill('minecraft:overworld', -30, -60, -30, 60, -35, 60, 'minecraft:air')"))
    ops.append(("sql", "select mc.fill('minecraft:overworld', -30, -61, -30, 60, -61, 60, 'minecraft:grass_block[snowy=false]')"))
    ops.append(("drain",))
    for _ in range(a.ops):
        r = rng.random()
        x = rng.randrange(0, R); z = rng.randrange(0, R); y = -60 + rng.randrange(0, 9)
        if r < 0.22:
            ops.append(("step", rng.randrange(1, a.max_step)))
        elif r < 0.38:
            x2 = x + rng.randrange(0, 8); z2 = z + rng.randrange(0, 8); y2 = y + rng.randrange(0, 2)
            ops.append(("fill", x, y, z, x2, y2, z2, rng.choice(BLOCKS) if rng.random() < 0.8 else "air"))
        elif r < 0.55:
            ops.append(("set", x, y, z, rng.choice(BLOCKS)))
        elif r < 0.68:
            ops.append(("set", x, -61, z, "air")); ops.append(("set", x + 1, -61, z, "air"))
        elif r < 0.80 or not a.lava:
            ops.append(("set", x, y, z, "water"))
        elif r < 0.84:
            x2 = x + rng.randrange(0, 10); z2 = z + rng.randrange(0, 10)
            ops.append(("fill", x, y, z, x2, y, z2, "water"))
        else:
            ops.append(("set", x, y, z, "lava"))
    ops.append(("step", 60))
    return ops


def run(a, db, ops):
    dsn = "host=/tmp port=%d user=postgres dbname=%s" % (a.port, db)
    c = psycopg2.connect(dsn); c.autocommit = True; cur = c.cursor()
    for kv in a.set:
        k, v = kv.split("=", 1)
        cur.execute("update mc.server_property set value = %s where key = %s", (v, k))
    cur.execute("truncate net.conn, mc.play_out, mc.block_event, mc.block_tick, mc.dyn_late_event; delete from mc.player")
    cur.execute("insert into net.conn (conn_id, state, compression, closing, view_cx, view_cz) values (1, 'play', -1, false, 0, 0)")
    cur.execute("insert into mc.player (uuid, name, conn_id, entity_id, chunk_x, chunk_z) values ('00000000-0000-0000-0000-00000000d001', 'Dyn', 1, 1, 0, 0)")
    cur.execute("insert into mc.game_rule (name, value) values ('minecraft:random_tick_speed', '0') on conflict (name) do update set value = '0'")
    cur.execute("select mc.generate_flat_area('minecraft:overworld', -3, -3, 4, 4)")
    cur.execute("select setseed(0.25)")
    ticks = []; npk = 0; raw = []; qraw = []
    for op in ops:
        if op[0] == "sql":
            cur.execute(op[1])
        elif op[0] == "drain":
            for _ in range(8):
                cur.execute("do $$ declare cur bigint; begin update mc.game_state set game_time = game_time + 1 returning game_time into cur; perform mc.dyn_step(cur); perform mc.broadcast_block_events(); "
                            "perform mc.dyn_release_late(); perform mc.broadcast_block_events(); end $$")
            cur.execute("delete from mc.play_out; truncate mc.block_tick, mc.block_event")
        elif op[0] == "fill":
            cur.execute("select mc.fill('minecraft:overworld', %s, %s, %s, %s, %s, %s, %s)", (*op[1:7], "minecraft:" + op[7]))
        elif op[0] == "set":
            cur.execute("do $$ declare m bigint; begin select coalesce(max(id), 0) into m from mc.block_event; perform mc.set_block('minecraft:overworld', %d, %d, %d, 'minecraft:%s'); "
                        "update mc.block_event e set kind = 'cells', x = (e.x >> 4) * 16, y = (e.y >> 4) * 16, z = (e.z >> 4) * 16, cells = mc.box_bitmap(e.x & 15, e.x & 15, e.y & 15, e.y & 15, e.z & 15, e.z & 15) "
                        "where e.id = (select min(id) from mc.block_event where id > m); end $$" % (op[1], op[2], op[3], op[4].replace("'", "''")))
        else:
            for _ in range(op[1]):
                cur.execute("do $$ declare cur bigint; begin update mc.game_state set game_time = game_time + 1 returning game_time into cur; perform mc.dyn_step(cur); perform mc.broadcast_block_events(); "
                            "perform mc.dyn_release_late(); perform mc.broadcast_block_events(); end $$")
                cur.execute("select coalesce(encode(sha256(string_agg(data, ''::bytea order by seq)), 'hex'), ''), count(*) from mc.play_out where conn_id = 1")
                h, n = cur.fetchone(); npk += n
                cur.execute("select encode(data, 'hex') from mc.play_out where conn_id = 1 order by seq"); raw.append([r[0] for r in cur.fetchall()])
                cur.execute("delete from mc.play_out")
                cur.execute("select coalesce(encode(sha256(convert_to(string_agg(x || ',' || y || ',' || z || ',' || kind::text || ',' || type || ',' || (due - (select game_time from mc.game_state)) || ',' || prio, ';' order by seq), 'UTF8')), 'hex'), '') from mc.block_tick")
                ticks.append(h + cur.fetchone()[0])
                cur.execute("select string_agg(x || ',' || y || ',' || z || ',' || kind::text || ',' || type || ',' || (due - (select game_time from mc.game_state)) || ',' || prio, ' ; ' order by seq) from mc.block_tick")
                qraw.append(cur.fetchone()[0] or "")
    cur.execute("select count(*) from mc.error_log where step = 'dyn_step'")
    errs = cur.fetchone()[0]
    cur.execute("select md5(string_agg(mc.get_block('minecraft:overworld', x, y, z), ',' order by x, y, z)) from generate_series(-2, %d) x, generate_series(-61, -40) y, generate_series(-2, %d) z" % (a.region + 14, a.region + 14))
    return dict(ticks=ticks, world=cur.fetchone()[0], npk=npk, errs=errs, raw=raw, qraw=qraw)


main()
