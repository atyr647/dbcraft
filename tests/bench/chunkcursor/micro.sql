-- micro benchmark of the chunk path: joins (hook_chunks + the delivery of their tails) and walkers crossing chunk borders (stream_chunks), explored world.  Prints one line per part.
\set ON_ERROR_STOP on
\if :{?xmod}\else\set xmod 25\endif
select set_config('mb.xmod', :'xmod', false) is null as c \gset
set client_min_messages = warning;
truncate net.conn_ctl, net.conn, net.inbox, net.outbox, mc.play_out, mc.chunk_wanted, mc.chunk_request, mc.chunk_wanted_view, mc.chunk_cursor, mc.visible, mc.vtrk, mc.wp;
delete from mc.player;
update mc.server_property set value = '10' where key in ('view-distance', 'simulation-distance');
update mc.server_property set value = 'async' where key = 'dbcraft.chunk-generation';
update mc.server_property set value = 'off' where key = 'dbcraft.tick-budget-ms';
update mc.server_property set value = '49' where key = 'dbcraft.join-chunks-inline';
update mc.server_property set value = '64' where key = 'dbcraft.chunk-batch-max';
update mc.server_property set value = '600' where key = 'dbcraft.chunk-budget-per-tick';
update mc.game_state set game_time = 700;
select count(mc.generate_flat('minecraft:overworld', cx, cz)) filter (where false) from generate_series(-14, 46) cx, generate_series(-14, 46) cz where not exists (select 1 from mc.chunk c where c.dimension = 'minecraft:overworld' and c.cx = cx and c.cz = cz);
select count(mc.chunk_packet('minecraft:overworld', cx, cz)) from generate_series(-14, 46) cx, generate_series(-14, 46) cz \gset
analyze mc.chunk;

create temp table res (part text, what text, ms numeric);
create or replace function pg_temp.mkplayers(p_from int, p_n int, p_view boolean) returns void language plpgsql as $$
begin
  insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, yaw, pitch, chunk_x, chunk_z, sent_qx, sent_qy, sent_qz, vis_dirty, last_sent_tick, gamemode, keepalive_sent_tick)
  select md5(g::text)::uuid, 'mb' || g, g, g, 8, 70, 8, 0, 0, 5 + (g * 7919) % 30, 5 + (g * 104729) % 30, mc.quant(8), mc.quant(70), mc.quant(8), false, 0, 1, 700 from generate_series(p_from, p_from + p_n - 1) g;
  update mc.player set view_distance_req = 10 where conn_id between p_from and p_from + p_n - 1;
  insert into net.conn (conn_id, state, name, uuid, compression, entity_id, gamemode, view_cx, view_cz, view_r)
  select conn_id, 'play', name, uuid, -1, entity_id, 1, case when p_view then chunk_x end, case when p_view then chunk_z end, case when p_view then 11 end from mc.player where conn_id between p_from and p_from + p_n - 1;
end $$;

-- part A: 50 joins at view distance 10 (hook_chunks), then the tails delivered tick by tick
select pg_temp.mkplayers(1, 50, false);
do $$
declare t0 timestamptz; th numeric := 0; td numeric := 0; c int; n int; calls int := 0; tot int := 0; chunks int := 0;
begin
  for c in 1 .. 50 loop
    t0 := clock_timestamp();
    select count(*) into n from net.hook_chunks(c, (select chunk_x from mc.player where conn_id = c), (select chunk_z from mc.player where conn_id = c), 10);
    th := th + extract(epoch from clock_timestamp() - t0) * 1000; chunks := chunks + n;
  end loop;
  loop
    t0 := clock_timestamp();
    n := mc.deliver_ready_chunks();
    td := td + extract(epoch from clock_timestamp() - t0) * 1000;
    exit when n = 0;
    calls := calls + 1; tot := tot + n;
    truncate mc.play_out;
  end loop;
  insert into res values ('A joins', 'hook_chunks ms per join (head ' || chunks / 50 || ' chunks)', round(th / 50, 2));
  insert into res values ('A joins', 'deliver: ' || calls || ' ticks, ' || tot || ' chunks; ms per tick', round(td / greatest(calls, 1), 2));
  insert into res values ('A joins', 'deliver total ms for the 50 tails', round(td, 1));
end $$;

-- part B: 500 walkers, each tick 1/25 of them cross a chunk border (+1 in x), delivered under the default budgets
truncate net.conn_ctl, net.conn, mc.play_out, mc.chunk_wanted, mc.chunk_request, mc.chunk_wanted_view, mc.chunk_cursor, mc.visible, mc.vtrk, mc.wp;
delete from mc.player;
select pg_temp.mkplayers(1, 500, true);
select pg_stat_reset() is null as r \gset
do $$
declare t0 timestamptz; ts numeric := 0; tk int; n int; mx numeric := 0; el numeric; rows_ int := 0; sent int := 0; crossed int := 0; k int;
begin
  for tk in 1 .. 50 loop
    update mc.player set chunk_x = chunk_x + 1 where conn_id % current_setting('mb.xmod')::int = tk % current_setting('mb.xmod')::int;
    get diagnostics k = row_count; crossed := crossed + k;
    t0 := clock_timestamp();
    n := net.stream_chunks();
    el := extract(epoch from clock_timestamp() - t0) * 1000;
    ts := ts + el; mx := greatest(mx, el);
    select count(*) into k from mc.chunk_wanted where dimension <> 'cursor'; rows_ := rows_ + k;
    select count(*) into k from mc.play_out; sent := sent + k;
    truncate mc.play_out;
  end loop;
  insert into res values ('B walkers', 'stream_chunks ms per tick (50 ticks, ' || crossed / 50 || ' crossings a tick)', round(ts / 50, 2));
  insert into res values ('B walkers', 'worst tick ms', round(mx, 2));
  insert into res values ('B walkers', 'wanted rows at the end of a tick, mean', round(rows_ / 50.0, 1));
  insert into res values ('B walkers', 'cursors at the end', (select count(*) from mc.chunk_cursor));
end $$;
select pg_stat_force_next_flush() is null as f \gset
select pg_sleep(0.6) is null as s \gset
select 'F ' || funcname, 'calls ' || calls || ' self ms per call', round((self_time / nullif(calls, 0))::numeric, 3) from pg_stat_user_functions where funcname in ('stream_chunks','deliver_ready_chunks','chunk_cursor_flush','chunk_packet','want_chunks') order by 1;
select * from res order by part, what;
truncate net.conn_ctl, net.conn, mc.play_out, mc.chunk_wanted, mc.chunk_request, mc.chunk_wanted_view, mc.chunk_cursor, mc.visible, mc.vtrk, mc.wp;
delete from mc.player;
