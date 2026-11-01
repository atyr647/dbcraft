#!/usr/bin/env python3
"""World-size scaling benchmark (docs/PERF-SCALE.md).

usage: tests/bench/scale/run_scale.py SERIES SIZE [SIZE ...] [--db NAME] [--ops a,b,c] [--no-ops]
  SERIES  label stored with every result ("flat", "dense", "lever-x" ...)
  SIZE    target number of chunks; the world is grown (spiral of 8x8 tiles, flat generator) to each size in turn, then measured
Needs a cluster started with tools/pg-dev.sh (DBCRAFT_PGDATA / DBCRAFT_PGPORT) and a migrated database that has the reference data loaded
and tests/bench/scale/helpers.sql applied.  Environment: SCALE_PORT (default 54444), SCALE_DATA (default /tmp/dbcraft-pg-scale), SCALE_DB.
Every operation is run COLD (the server is restarted and the OS page cache dropped, then 200 random keys, each touching mostly uncached pages)
and WARM (the same 200 keys again, everything cached).  Latencies are taken inside PostgreSQL with clock_timestamp() around each call, so psql and
network time are excluded.  Results go to scale.samples / scale.sizes in the database and to tests/bench/scale/results/SERIES.json.
"""
import json, os, subprocess, sys, time, statistics

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
PORT = os.environ.get("SCALE_PORT", "54444")
DATA = os.environ.get("SCALE_DATA", "/tmp/dbcraft-pg-scale")
DB = os.environ.get("SCALE_DB", "scale")
ENV = dict(os.environ, PGHOST="/tmp", PGPORT=PORT, PGUSER="postgres", DBCRAFT_PGDATA=DATA, DBCRAFT_PGPORT=PORT)
DIM = "minecraft:overworld"
OPS_ALL = ["get_block", "block_at", "blocks_in", "chunk_packet_cached", "set_block", "rebuild_after_edit", "generate_batch64", "join441", "border_step"]


def psql(sql, db=None, check=True):
    p = subprocess.run(["psql", "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-d", db or DB], input=sql, capture_output=True, text=True, env=ENV)
    if check and p.returncode:
        sys.exit("psql failed:\n" + p.stderr + "\nSQL:\n" + sql[:600])
    return p.stdout.strip()


def pgdev(cmd):
    subprocess.run([os.path.join(ROOT, "tools", "pg-dev.sh"), cmd], env=ENV, capture_output=True, check=True)


def cold_restart():
    pgdev("stop")
    subprocess.run("sync; echo 3 > /proc/sys/vm/drop_caches", shell=True, check=True)
    pgdev("start")


def cluster_mb():
    return int(subprocess.run(["du", "-sm", DATA], capture_output=True, text=True).stdout.split()[0])


def load():
    return os.getloadavg()[0]


def op_sql(op, size, series, phase):
    head = f"set jit = off; do $$ declare k record; t0 timestamptz; size int := {size}; ser text := 'SERIES'; ph text := 'PHASE'; "
    head = head.replace("SERIES", series).replace("PHASE", phase)
    rec = "insert into scale.samples values (size, ser, 'OP', ph, extract(epoch from clock_timestamp() - t0) * 1e6);"
    if op == "get_block":
        body = f"for k in select * from scale.keys where n <= 200 order by n loop t0 := clock_timestamp(); perform mc.get_block('{DIM}', k.x, k.y, k.z); {rec.replace('OP', op)} end loop;"
    elif op == "block_at":
        body = f"for k in select * from scale.keys where n <= 200 order by n loop t0 := clock_timestamp(); perform * from mc.block_at('{DIM}', k.x, k.y, k.z); {rec.replace('OP', op)} end loop;"
    elif op == "blocks_in":
        body = (f"for k in select * from scale.keys where n <= 200 order by n loop t0 := clock_timestamp(); "
                f"perform count(*) from mc.blocks_in('{DIM}', k.x, k.y, k.z, k.x + 3, k.y + 3, k.z + 3); {rec.replace('OP', op)} end loop;")
    elif op == "chunk_packet_cached":
        body = f"for k in select * from scale.keys where n <= 200 order by n loop t0 := clock_timestamp(); perform mc.chunk_packet('{DIM}', k.cx, k.cz); {rec.replace('OP', op)} end loop;"
    elif op == "set_block":
        blk = "minecraft:stone" if phase == "cold" else "minecraft:gold_block"
        body = f"for k in select * from scale.keys where n > 1000 order by n loop t0 := clock_timestamp(); perform mc.set_block('{DIM}', k.x, k.y, k.z, '{blk}'); {rec.replace('OP', op)} end loop;"
    elif op == "rebuild_after_edit":
        blk = "minecraft:diamond_block" if phase == "cold" else "minecraft:emerald_block"
        body = (f"for k in select * from scale.keys where n > 1000 order by n loop perform mc.set_block('{DIM}', k.x, k.y, k.z, '{blk}'); "
                f"t0 := clock_timestamp(); perform mc.chunk_packet('{DIM}', k.cx, k.cz); {rec.replace('OP', op)} end loop;")
    elif op == "generate_batch64":
        # 20 batches of 8x8 chunks at random far positions (random index insertion points), each batch timed
        return (f"set jit = off; do $$ declare i int; cxs int[]; czs int[]; t0 timestamptz; ox int; oz int; "
                f"begin for i in 1 .. 20 loop ox := (random() * 2000000 - 1000000)::int; oz := (random() * 2000000 - 1000000)::int; if abs(ox) < 100000 then ox := ox + 200000; end if; "
                f"select array_agg(ox + a), array_agg(oz + b) into cxs, czs from generate_series(0, 7) a, generate_series(0, 7) b; "
                f"t0 := clock_timestamp(); perform mc.generate_batch('{DIM}', cxs, czs); "
                f"insert into scale.samples values ({size}, '{series}', 'generate_batch64', '{phase}', extract(epoch from clock_timestamp() - t0) * 1e6); end loop; end $$;")
    elif op in ("join441", "border_step"):
        return (f"set jit = off; do $$ declare i int; k record; t0 timestamptz; cnt int; "
                f"begin for k in select * from scale.keys where n between 2001 and 2030 order by n loop "
                + ("t0 := clock_timestamp(); select count(*) into cnt from net.hook_chunks(-1, k.cx, k.cz, 9); "
                   if op == "join441" else
                   "perform count(*) from net.hook_chunks(-1, k.cx, k.cz, 9); t0 := clock_timestamp(); select count(*) into cnt from net.hook_chunks(-1, k.cx + 1, k.cz, 9); ")
                + f"insert into scale.samples values ({size}, '{series}', '{op}', '{phase}', extract(epoch from clock_timestamp() - t0) * 1e6); "
                  f"delete from mc.chunk_wanted where conn_id = -1; end loop; end $$;")
    else:
        sys.exit("unknown op " + op)
    return head + "begin " + body + " end $$;"


def pick_keys(size):
    # 200 read keys (n 1..200), 200 edit keys (n 1001..1200, other chunks), 30 join centres (n 2001..2030) inside the completely generated square of tiles
    psql(f"""
select setseed(0.314159);
truncate scale.keys;
with r as (select cx, cz, row_number() over () n from (select cx, cz from mc.chunk where dimension = '{DIM}' order by random() limit 400) q)
insert into scale.keys select case when n <= 200 then n else n + 800 end, cx, cz, cx * 16 + (random() * 15)::int, -64 + (random() * 5)::int, cz * 16 + (random() * 15)::int from r;
with t as (select v::int tiles from scale.state where k = 'tile_{DIM}'),
     kk as (select (select max(k) from generate_series(0, 200) k where (2 * k + 1) * (2 * k + 1) <= t.tiles) k from t)
insert into scale.keys select 2000 + g, c.cx, c.cz, 0, 0, 0
from kk, generate_series(1, 30) g,
     lateral (select (-8 * greatest(kk.k, 1) + 10 + (random() * greatest(16 * greatest(kk.k, 1) - 13, 0))::int)::int cx,
                     (-8 * greatest(kk.k, 1) + 10 + (random() * greatest(16 * greatest(kk.k, 1) - 13, 0))::int)::int cz) c;
""")


def record_sizes(size, series):
    psql(f"""delete from scale.sizes where size_chunks = {size} and series = '{series}';
insert into scale.sizes
select {size}, '{series}', c.relname, c.reltuples::bigint,
       pg_relation_size(c.oid), coalesce(pg_total_relation_size(c.reltoastrelid), 0), pg_indexes_size(c.oid)
from pg_class c where c.relnamespace = 'mc'::regnamespace and c.relkind = 'r' and c.relname in ('chunk', 'chunk_section', 'chunk_light', 'chunk_cache', 'block_entity');""")


def plans(size, series):
    """EXPLAIN (FORMAT JSON) of the statements a world operation runs; report the node types so a plan flip or a sequential scan is visible."""
    k = psql("select cx, cz from scale.keys where n = 1")
    cx, cz = k.split("|")
    x, z = int(cx) * 16 + 3, int(cz) * 16 + 5
    stmts = {
        "section_lookup": f"select bits, palette, data from mc.chunk_section where dimension = '{DIM}' and cx = {cx} and cz = {cz} and sy = -4",
        "chunk_exists": f"select 1 from mc.chunk where dimension = '{DIM}' and cx = {cx} and cz = {cz}",
        "chunk_packet_join": (f"select k.packet from mc.chunk c join mc.chunk_cache k on k.dimension = c.dimension and k.cx = c.cx and k.cz = c.cz and k.version = c.version "
                              f"where c.dimension = '{DIM}' and c.cx = {cx} and c.cz = {cz} and not c.dirty and not c.hm_dirty"),
        "join_main": (f"select k.packet from generate_series(-10, 10) dx cross join generate_series(-10, 10) dz join mc.chunk c on c.dimension = '{DIM}' and c.cx = {cx} + dx and c.cz = {cz} + dz "
                      f"left join mc.chunk_cache k on k.dimension = c.dimension and k.cx = c.cx and k.cz = c.cz and k.version = c.version"),
        "light_read": f"select idx, sky, block from mc.chunk_light where dimension = '{DIM}' and cx = {cx} and cz = {cz} order by idx",
        "blocks_in_sections": (f"select s.* from mc.chunk_section s where s.dimension = '{DIM}' and s.cx between {x} >> 4 and {x + 3} >> 4 and s.cz between {z} >> 4 and {z + 3} >> 4 "
                               f"and s.sy between -4 and -4"),
    }
    out = {}
    for name, sql in stmts.items():
        j = json.loads(psql("set jit = off; explain (format json) " + sql))
        nodes = []

        def walk(p):
            nodes.append(p["Node Type"] + (" on " + p["Relation Name"] if "Relation Name" in p else "") + (" using " + p["Index Name"] if "Index Name" in p else ""))
            for c in p.get("Plans", []):
                walk(c)
        walk(j[0]["Plan"])
        out[name] = {"nodes": nodes, "seq_scan": any(n.startswith("Seq Scan on mc.") for n in nodes), "est_cost": j[0]["Plan"]["Total Cost"]}
    return out


def main():
    args = sys.argv[1:]
    global DB
    if "--db" in args:
        i = args.index("--db"); DB = args[i + 1]; del args[i:i + 2]
    ops = OPS_ALL
    if "--ops" in args:
        i = args.index("--ops"); ops = args[i + 1].split(","); del args[i:i + 2]
    grow = "scale.grow_flat"
    if "--grow" in args:
        i = args.index("--grow"); grow = "scale." + args[i + 1]; del args[i:i + 2]
    no_ops = "--no-ops" in args
    if no_ops: args.remove("--no-ops")
    series, sizes = args[0], [int(a) for a in args[1:]]
    os.makedirs(os.path.join(ROOT, "tests", "bench", "scale", "results"), exist_ok=True)
    resfile = os.path.join(ROOT, "tests", "bench", "scale", "results", f"{series}.json")
    results = json.load(open(resfile)) if os.path.exists(resfile) else {}
    for size in sizes:
        r = results.setdefault(str(size), {})
        print(f"=== {series} {size} chunks   load {load():.2f}   cluster {cluster_mb()} MB", flush=True)
        # growth, with the checkpoint and WAL accounting
        pre = psql("select pg_current_wal_lsn(), (select checkpoints_timed || ',' || checkpoints_req || ',' || buffers_checkpoint from pg_stat_bgwriter), (select count(*) from mc.chunk)").split("|")
        t0 = time.time()
        psql(f"call {grow}({size})")
        dt = time.time() - t0
        post = psql("select pg_current_wal_lsn(), (select checkpoints_timed || ',' || checkpoints_req || ',' || buffers_checkpoint from pg_stat_bgwriter), (select count(*) from mc.chunk)").split("|")
        wal = int(psql(f"select pg_wal_lsn_diff('{post[0]}', '{pre[0]}')::bigint"))
        made = int(post[2]) - int(pre[2])
        cp0, cp1 = [int(v) for v in pre[1].split(",")], [int(v) for v in post[1].split(",")]
        r["growth"] = {"chunks_made": made, "seconds": round(dt, 2), "chunks_per_s": round(made / dt, 1) if dt > 0 and made else None, "wal_bytes": wal,
                       "wal_bytes_per_chunk": round(wal / made) if made else None,
                       "checkpoints_timed": cp1[0] - cp0[0], "checkpoints_requested": cp1[1] - cp0[1], "buffers_written_by_checkpoints": cp1[2] - cp0[2]}
        print("  growth:", r["growth"], flush=True)
        t0 = time.time(); psql("vacuum (analyze) mc.chunk, mc.chunk_section, mc.chunk_light, mc.chunk_cache"); r["vacuum_analyze_s"] = round(time.time() - t0, 2)
        psql("checkpoint")
        n = int(psql("select count(*) from mc.chunk")); r["chunks"] = n
        record_sizes(size, series)
        r["sizes"] = {row.split("|")[0]: [int(v) for v in row.split("|")[1:]] for row in psql(
            f"select rel, rows, heap_bytes, toast_bytes, index_bytes from scale.sizes where size_chunks = {size} and series = '{series}' order by rel").splitlines()}
        r["dead_tuples"] = psql("select string_agg(relname || ':' || n_dead_tup || '/' || autovacuum_count || '/' || autoanalyze_count, ' ') from pg_stat_user_tables where schemaname = 'mc' and relname like 'chunk%'")
        r["db_mb"] = int(psql("select pg_database_size(current_database()) / 1048576"))
        r["cluster_mb"] = cluster_mb()
        pick_keys(size)
        r["plans"] = plans(size, series)
        print("  sizes (bytes: rows heap toast idx):", r["sizes"], " cluster MB:", r["cluster_mb"], flush=True)
        for name, p in r["plans"].items():
            print(f"  plan {name:20s} {'SEQ SCAN!' if p['seq_scan'] else 'ok'}  cost {p['est_cost']:.1f}  {p['nodes'][:3]}", flush=True)
        if not no_ops:
            psql(f"delete from scale.samples where size_chunks = {size} and series = '{series}'")
            r["load_before_ops"] = round(load(), 2)
            for op in ops:
                cold_restart()
                for phase in ("cold", "warm"):
                    psql(op_sql(op, size, series, phase))
                if op == "generate_batch64":      # remove the far-away chunks again so the next sizes measure a world of exactly the target size
                    psql(f"delete from mc.chunk where dimension = '{DIM}' and (abs(cx) >= 100000 or abs(cz) >= 100000); vacuum mc.chunk, mc.chunk_section, mc.chunk_light, mc.chunk_cache;")
                rows = psql(f"""select phase, count(*), round(percentile_cont(0.5) within group (order by us)::numeric, 1), round(percentile_cont(0.99) within group (order by us)::numeric, 1),
                                round(max(us)::numeric, 1), round(avg(us)::numeric, 1) from scale.samples where size_chunks = {size} and series = '{series}' and op = '{op}' group by phase order by phase""")
                r.setdefault("ops", {})[op] = {}
                for line in rows.splitlines():
                    ph, cnt, p50, p99, mx, avg = line.split("|")
                    r["ops"][op][ph] = {"n": int(cnt), "p50_us": float(p50), "p99_us": float(p99), "max_us": float(mx), "mean_us": float(avg)}
                print(f"  {op:22s} " + "   ".join(f"{ph}: p50 {v['p50_us']:>10.1f} us  p99 {v['p99_us']:>10.1f} us" for ph, v in r["ops"][op].items()), flush=True)
            r["load_after_ops"] = round(load(), 2)
        json.dump(results, open(resfile, "w"), indent=1)
    print("done; results in", resfile)


if __name__ == "__main__":
    main()
