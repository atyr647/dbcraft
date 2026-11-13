#!/usr/bin/env bash
# Prototype measurement of the narrow position table (docs/PERF-PAIRING.md, "Narrow position table"): the cost of one mover's UPDATE in the wide mc.player row against a narrow UNLOGGED
# table with the statement shape of mc.apply_player_moves (sql/431: one UPDATE ... FROM unnest(...) for all movers of the tick), every statement its OWN transaction like a tick (so page
# pruning and HOT updates work as in the server), a vacuum of both tables every 20 statements (the gateway's maintenance does that once a second).
#   usage: PGHOST=/tmp PGPORT=.. PGUSER=postgres PGDATABASE=scratch tools/scoreboard/pos_proto_bench.sh [MOVERS=500] [ITER=200]
# WARNING: truncates mc.player of that database (use a scratch database with the dbcraft schema).
set -euo pipefail
M=${1:-500}; N=${2:-200}
psql -X -q -v ON_ERROR_STOP=1 <<SQL
create schema if not exists pp;
drop table if exists pp.pos;
create unlogged table pp.pos (entity_id int primary key, x float8 not null, y float8 not null, z float8 not null, yaw real not null, pitch real not null, on_ground boolean not null,
                              chunk_x int not null, chunk_z int not null, last_move_tick bigint, vis_dirty boolean not null default false, vis_x float8, vis_z float8, vis_ocx int, vis_ocz int, yaw_prev real) with (fillfactor = 50);
truncate mc.player cascade;
insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, yaw, pitch, chunk_x, chunk_z)
select md5(i::text)::uuid, 'p' || i, i, i, random() * 800, 70, random() * 800, random() * 360, 0, 0, 0 from generate_series(1, 500) i;
update mc.player set vis_x = x, vis_z = z, last_move_tick = 0, trk_start = 0, wp_state = 1;
insert into pp.pos select entity_id, x, y, z, yaw, pitch, on_ground, chunk_x, chunk_z, last_move_tick, vis_dirty, vis_x, vis_z, vis_ocx, vis_ocz, yaw from mc.player;
vacuum analyze mc.player; vacuum analyze pp.pos;
create or replace function pp.upd(p_tbl text, p_movers int, p_tick int) returns float8 language plpgsql as \$\$
declare t0 timestamptz; ids int[]; xs float8[]; zs float8[];
begin
  select array_agg(entity_id order by entity_id), array_agg(random() * 800), array_agg(random() * 800) into ids, xs, zs from (select entity_id from pp.pos order by entity_id limit p_movers) s;
  t0 := clock_timestamp();
  execute format('update %s p set x = n.x, y = 70, z = n.z, yaw = (random() * 360)::real, pitch = 0, on_ground = true, chunk_x = floor(n.x / 16)::int, chunk_z = floor(n.z / 16)::int,
           last_move_tick = %s, vis_dirty = (n.x - p.vis_x) ^ 2 + (n.z - p.vis_z) ^ 2 >= 16, vis_ocx = case when p.vis_dirty then p.vis_ocx else p.chunk_x end,
           vis_ocz = case when p.vis_dirty then p.vis_ocz else p.chunk_z end, yaw_prev = p.yaw
      from unnest(%L::int[], %L::float8[], %L::float8[]) as n(id, x, z) where p.entity_id = n.id', p_tbl, p_tick, ids, xs, zs);
  return extract(epoch from clock_timestamp() - t0) * 1e6 / p_movers;
end \$\$;
SQL
out=$(mktemp)
for i in $(seq 1 "$N"); do
  echo "select 'wide', pp.upd('mc.player', $M, $i);"
  echo "select 'narrow', pp.upd('pp.pos', $M, $i);"
  if [ $((i % 20)) -eq 0 ]; then echo "vacuum mc.player; vacuum pp.pos;"; fi
done | psql -X -q -At -F ' ' > "$out"
for k in wide narrow; do
  grep "^$k " "$out" | awk -v k=$k -v m=$M '{ a[NR]=$2; s+=$2 } END { n=asort(a); printf "%-7s %d movers: mean %.1f us per mover, median %.1f, p95 %.1f (%.2f ms per tick of that many movers)\n", k, m, s/n, a[int(n/2)], a[int(n*0.95)], s/n*m/1000 }'
done
psql -X -q -At -c "select 'mc.player ' || pg_size_pretty(pg_relation_size('mc.player')) || ', pp.pos ' || pg_size_pretty(pg_relation_size('pp.pos')) || ', columns of mc.player: ' || (select count(*) from pg_attribute where attrelid = 'mc.player'::regclass and attnum > 0 and not attisdropped)"
psql -X -q -c "drop schema pp cascade" > /dev/null 2>&1
psql -X -q -c "truncate mc.player cascade"
rm -f "$out"
