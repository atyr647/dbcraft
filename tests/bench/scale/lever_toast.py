#!/usr/bin/env python3
"""TOAST lever: compression method and storage for the chunk packet cache and for the section data (docs/PERF-SCALE.md).

usage: tests/bench/scale/lever_toast.py [DB]      default DB lever_dense (a dense world from tests/bench/scale/dense.sql, ~5,000 chunks)
Builds copies of mc.chunk_cache (pglz = today, lz4, external = never compressed) and of mc.chunk_section (pglz, lz4) in schema "lever", then measures
  join   : 441 cached packets read and cut to their body, the way net.hook_chunks does it (30 random centres)  -> ms per join
  secget : mc.get_block's read path on random sections: select bits, palette, data + mc.entry_at (200 random keys) -> us per read
each COLD (server restarted, OS page cache dropped) and WARM, plus the on-disk size of every variant.
"""
import os, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run_scale as R

DB = sys.argv[1] if len(sys.argv) > 1 else "lever_dense"
R.DB = DB
Q = R.psql

if not os.environ.get("LEVER_SKIP_BUILD"):
  Q("""
create schema if not exists lever;
drop table if exists lever.cache_pglz, lever.cache_lz4, lever.cache_ext, lever.sec_pglz, lever.sec_lz4 cascade;
create table lever.cache_pglz (dimension text not null, cx int not null, cz int not null, version bigint not null, packet bytea not null, primary key (dimension, cx, cz));
alter table lever.cache_pglz alter column packet set compression pglz;
create table lever.cache_lz4 (like lever.cache_pglz including all);
alter table lever.cache_lz4 alter column packet set compression lz4;
create table lever.cache_ext (like lever.cache_pglz including all);
alter table lever.cache_ext alter column packet set storage external;
insert into lever.cache_pglz select dimension, cx, cz, version, packet || ''::bytea from mc.chunk_cache where dimension = 'minecraft:overworld';
insert into lever.cache_lz4  select dimension, cx, cz, version, packet || ''::bytea from mc.chunk_cache where dimension = 'minecraft:overworld';
insert into lever.cache_ext  select dimension, cx, cz, version, packet || ''::bytea from mc.chunk_cache where dimension = 'minecraft:overworld';

create table lever.sec_pglz (like mc.chunk_section including defaults including storage including indexes including constraints);
alter table lever.sec_pglz alter column data set compression pglz, alter column palette set compression pglz;
create table lever.sec_lz4 (like lever.sec_pglz including all);
alter table lever.sec_lz4 alter column data set compression lz4, alter column palette set compression lz4, alter column biome_data set compression lz4;
insert into lever.sec_pglz select dimension, cx, cz, sy, block_count, fluid_count, palette, bits, data || ''::bytea, biome_palette, biome_bits, biome_data from mc.chunk_section where dimension = 'minecraft:overworld';
insert into lever.sec_lz4  select dimension, cx, cz, sy, block_count, fluid_count, palette, bits, data || ''::bytea, biome_palette, biome_bits, biome_data from mc.chunk_section where dimension = 'minecraft:overworld';
vacuum analyze lever.cache_pglz, lever.cache_lz4, lever.cache_ext, lever.sec_pglz, lever.sec_lz4;
checkpoint;
""")
print("variants built; sizes (MB total incl. toast and indexes) and methods actually used:")
for t in ("cache_pglz", "cache_lz4", "cache_ext", "sec_pglz", "sec_lz4"):
    col = "packet" if t.startswith("cache") else "data"
    size = Q(f"select (pg_total_relation_size('lever.{t}'::regclass) / 1048576.0)::numeric(8,1)")
    meth = Q(f"select 'method=' || coalesce((select pg_column_compression({col}) from lever.{t} limit 1), 'none') || '  avg stored bytes ' || avg(pg_column_size({col}))::int || ' of ' || avg(length({col}))::int from lever.{t}")
    print(f"  {t:11s} {size:>8} MB   {meth}")

# keys: 30 join centres inside the fully generated square, 200 random section keys
Q("""
create table if not exists scale.lkeys (n int primary key, cx int, cz int, sy int, x int, y int, z int);
truncate scale.lkeys;
select setseed(0.2718);
insert into scale.lkeys select n, -14 + (random() * 35)::int, -14 + (random() * 35)::int, 0, 0, 0, 0 from generate_series(1, 30) n;
insert into scale.lkeys select 1000 + row_number() over (), cx, cz, -4 + (random() * 23)::int, cx * 16 + (random() * 15)::int, 0, cz * 16 + (random() * 15)::int
  from (select cx, cz from mc.chunk where dimension = 'minecraft:overworld' order by random() limit 200) q;
update scale.lkeys set y = sy * 16 + (random() * 15)::int where n > 1000;
create table if not exists scale.lsamples (variant text, op text, phase text, us numeric);
delete from scale.lsamples;
""")


def block(variant, op, phase):
    if op == "join":
        t = f"lever.{variant}"
        body = (f"for k in select * from scale.lkeys where n <= 30 order by n loop t0 := clock_timestamp(); "
                f"select count(*), sum(length(mc.packet_body(c.packet))) into cnt, bytes from generate_series(-10, 10) dx cross join generate_series(-10, 10) dz "
                f"join {t} c on c.dimension = 'minecraft:overworld' and c.cx = k.cx + dx and c.cz = k.cz + dz; "
                f"insert into scale.lsamples values ('{variant}', 'join', '{phase}', extract(epoch from clock_timestamp() - t0) * 1e6); end loop;")
    else:
        t = f"lever.{variant}"
        body = (f"for k in select * from scale.lkeys where n > 1000 order by n loop t0 := clock_timestamp(); "
                f"select s.bits, s.palette, s.data into rec from {t} s where s.dimension = 'minecraft:overworld' and s.cx = k.cx and s.cz = k.cz and s.sy = k.sy; "
                f"e := case when rec.bits = 0 then 0 else mc.entry_at(rec.bits, rec.data, mc.section_idx(k.x, k.y, k.z)) end; "
                f"insert into scale.lsamples values ('{variant}', 'secget', '{phase}', extract(epoch from clock_timestamp() - t0) * 1e6); end loop;")
    return f"set jit = off; do $$ declare k record; rec record; t0 timestamptz; cnt int; bytes bigint; e int; begin {body} end $$;"


for variant, op in [("cache_pglz", "join"), ("cache_lz4", "join"), ("cache_ext", "join"), ("sec_pglz", "secget"), ("sec_lz4", "secget")]:
    R.cold_restart()
    for phase in ("cold", "warm"):
        Q(block(variant, op, phase))
rows = Q("""select variant, op, phase, count(*), round(percentile_cont(0.5) within group (order by us)::numeric, 1), round(percentile_cont(0.99) within group (order by us)::numeric, 1)
            from scale.lsamples group by variant, op, phase order by op, variant, phase""")
print("\nvariant      op      phase  n   p50_us      p99_us")
for line in rows.splitlines():
    v, op, ph, n, p50, p99 = line.split("|")
    print(f"{v:11s}  {op:7s} {ph:5s} {n:>3s} {float(p50):>10.1f} {float(p99):>11.1f}")
