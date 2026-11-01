#!/usr/bin/env python3
"""Layout levers on the chunk and chunk_cache tables (docs/PERF-SCALE.md): partitioning, a covering index, and the primary key.

usage: tests/bench/scale/lever_partition.py [DB]       default lever_flat (a ~50k chunk flat world; needs scale.keys from any run_scale.py run)
Variants, each a pair of tables (chunk-like: dimension, cx, cz, version, dirty, hm_dirty; cache-like: + packet) filled from the real tables:
  plain    today's layout: primary key (dimension, cx, cz)
  cover    plain + a unique index (dimension, cx, cz) INCLUDE (version, dirty, hm_dirty) so the chunk side of the join is an index-only scan
  h16/h64  hash partitioned on (cx, cz), 16 / 64 partitions
  r32      range partitioned on cx in stripes of 32 chunks
  bigkey   one bigint primary key packed from (cx, cz) instead of (text, int, int)
Measured WARM (a warm-up pass first): 'join' = the 441-chunk read of net.hook_chunks over 30 random centres (ms), 'lookup' = one chunk by key, 200 random keys (us).
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run_scale as R

DB = sys.argv[1] if len(sys.argv) > 1 else "lever_flat"
R.DB = DB
Q = R.psql
D = "minecraft:overworld"

ddl = ["create schema if not exists lever;"]
for v in ("plain", "cover", "h16", "h64", "r32", "bigkey"):
    ddl.append(f"drop table if exists lever.c_{v}, lever.k_{v} cascade;")
for v in ("plain", "cover"):
    ddl.append(f"create table lever.c_{v} (dimension text not null, cx int not null, cz int not null, version bigint not null, dirty boolean not null, hm_dirty boolean not null, primary key (dimension, cx, cz));")
    ddl.append(f"create table lever.k_{v} (dimension text not null, cx int not null, cz int not null, version bigint not null, packet bytea not null, primary key (dimension, cx, cz));")
ddl.append("create unique index c_cover_incl on lever.c_cover (dimension, cx, cz) include (version, dirty, hm_dirty);")
for v, n in (("h16", 16), ("h64", 64)):
    ddl.append(f"create table lever.c_{v} (dimension text not null, cx int not null, cz int not null, version bigint not null, dirty boolean not null, hm_dirty boolean not null, primary key (dimension, cx, cz)) partition by hash (cx, cz);")
    ddl.append(f"create table lever.k_{v} (dimension text not null, cx int not null, cz int not null, version bigint not null, packet bytea not null, primary key (dimension, cx, cz)) partition by hash (cx, cz);")
    for t in ("c", "k"):
        ddl.append(f"select format('create table lever.{t}_{v}_p%s partition of lever.{t}_{v} for values with (modulus {n}, remainder %s)', g, g) from generate_series(0, {n - 1}) g \\gexec")
ddl.append("create table lever.c_r32 (dimension text not null, cx int not null, cz int not null, version bigint not null, dirty boolean not null, hm_dirty boolean not null, primary key (dimension, cx, cz)) partition by range (cx);")
ddl.append("create table lever.k_r32 (dimension text not null, cx int not null, cz int not null, version bigint not null, packet bytea not null, primary key (dimension, cx, cz)) partition by range (cx);")
for t in ("c", "k"):
    ddl.append(f"select format('create table lever.{t}_r32_p%s partition of lever.{t}_r32 for values from (%s) to (%s)', g + 100, g * 32, g * 32 + 32) from generate_series(-5, 4) g \\gexec")
    ddl.append(f"create table lever.{t}_r32_default partition of lever.{t}_r32 default;")
ddl.append("create table lever.c_bigkey (key bigint primary key, version bigint not null, dirty boolean not null, hm_dirty boolean not null);")
ddl.append("create table lever.k_bigkey (key bigint primary key, version bigint not null, packet bytea not null);")
for v in ("plain", "cover", "h16", "h64", "r32"):
    ddl.append(f"insert into lever.c_{v} select dimension, cx, cz, version, dirty, hm_dirty from mc.chunk where dimension = '{D}' order by cx, cz;")
    ddl.append(f"insert into lever.k_{v} select dimension, cx, cz, version, packet from mc.chunk_cache where dimension = '{D}' order by cx, cz;")
ddl.append(f"insert into lever.c_bigkey select ((cx + 1048576)::bigint << 21) | (cz + 1048576), version, dirty, hm_dirty from mc.chunk where dimension = '{D}' order by cx, cz;")
ddl.append(f"insert into lever.k_bigkey select ((cx + 1048576)::bigint << 21) | (cz + 1048576), version, packet from mc.chunk_cache where dimension = '{D}' order by cx, cz;")
ddl.append("vacuum analyze;")
ddl.append("checkpoint;")
if not os.environ.get("LEVER_SKIP_BUILD"):
    Q("\n".join(ddl))


def join_sql(v):
    if v == "bigkey":
        return ("select count(*), sum(length(mc.packet_body(k.packet))) into cnt, bytes from generate_series(-10, 10) dx cross join generate_series(-10, 10) dz "
                "join lever.c_bigkey c on c.key = (((r.cx + dx + 1048576)::bigint << 21) | (r.cz + dz + 1048576)) "
                "left join lever.k_bigkey k on k.key = c.key and k.version = c.version and not c.dirty and not c.hm_dirty;")
    return (f"select count(*), sum(length(mc.packet_body(k.packet))) into cnt, bytes from generate_series(-10, 10) dx cross join generate_series(-10, 10) dz "
            f"join lever.c_{v} c on c.dimension = '{D}' and c.cx = r.cx + dx and c.cz = r.cz + dz "
            f"left join lever.k_{v} k on k.dimension = c.dimension and k.cx = c.cx and k.cz = c.cz and k.version = c.version and not c.dirty and not c.hm_dirty;")


def lookup_sql(v):
    if v == "bigkey":
        return f"select c.version into ver from lever.c_bigkey c where c.key = (((r.cx + 1048576)::bigint << 21) | (r.cz + 1048576));"
    return f"select c.version into ver from lever.c_{v} c where c.dimension = '{D}' and c.cx = r.cx and c.cz = r.cz;"


Q("create table if not exists scale.psamples (variant text, op text, us numeric); delete from scale.psamples;")
for v in ("plain", "cover", "h16", "h64", "r32", "bigkey"):
    for op, keysel, body in (("join", "n between 2001 and 2030", join_sql(v)), ("lookup", "n <= 200", lookup_sql(v))):
        rec = f"insert into scale.psamples values ('{v}', '{op}', extract(epoch from clock_timestamp() - t0) * 1e6);"
        Q(f"set jit = off; do $$ declare r record; t0 timestamptz; cnt int; bytes bigint; ver bigint; pass int; begin "
          f"for pass in 1 .. 2 loop for r in select * from scale.keys where {keysel} order by n loop t0 := clock_timestamp(); {body} "
          f"if pass = 2 then {rec} end if; end loop; end loop; end $$;")

print("variant  op      n   p50_us     p99_us   | table sizes (MB, with indexes): chunk-like + cache-like")
for line in Q("select variant, op, count(*), round(percentile_cont(0.5) within group (order by us)::numeric, 1), round(percentile_cont(0.99) within group (order by us)::numeric, 1) from scale.psamples group by variant, op order by op, variant").splitlines():
    v, op, n, p50, p99 = line.split("|")
    print(f"{v:8s} {op:7s} {n:>3s} {float(p50):>9.1f} {float(p99):>10.1f}")
print("\nsizes (MB):")
for v in ("plain", "cover", "h16", "h64", "r32", "bigkey"):
    c = Q(f"select (sum(pg_total_relation_size(c.oid)) / 1048576.0)::numeric(8,2) from pg_class c where c.relnamespace = 'lever'::regnamespace and c.relkind in ('r', 'p') and c.relname like 'c\\_{v}%' and not c.relispartition")
    k = Q(f"select (sum(pg_total_relation_size(c.oid)) / 1048576.0)::numeric(8,1) from pg_class c where c.relnamespace = 'lever'::regnamespace and c.relkind in ('r', 'p') and c.relname like 'k\\_{v}%' and not c.relispartition")
    ci = Q(f"select (sum(pg_indexes_size(c.oid)) / 1048576.0)::numeric(8,2) from pg_class c where c.relnamespace = 'lever'::regnamespace and c.relkind in ('r') and c.relname like 'c\\_{v}%'")
    print(f"  {v:8s} chunk-like {c:>7} MB (indexes {ci} MB)   cache-like {k:>7} MB")
print("\nplanning cost of one ad-hoc lookup (EXPLAIN SUMMARY, ms):")
for v in ("plain", "h16", "h64", "r32"):
    out = Q(f"set jit = off; explain (summary on, costs off) select version from lever.c_{v} where dimension = '{D}' and cx = 7 and cz = 9")
    plan = [l for l in out.splitlines() if "Planning Time" in l]
    removed = [l.strip() for l in out.splitlines() if "Subplans Removed" in l]
    print(f"  {v:6s} {plan[0].strip() if plan else '?'}  {removed[0] if removed else ''}")
