-- What does dbcraft.entity-mode cost when there is NOTHING to simulate?  Players stand still, no entities exist.
-- usage: psql -X -v players=50 -v mode=off|inline|split -v ticks=300 -f tests/bench/mobs2/idle.sql         (a database made by tests/e2e/setup.sh; it is changed: players, entities, the property)
-- Measures the WALL time of (this backend alone: the machine is shared, so compare the p50 and the minimum; /proc/self/schedstat has the resolution of a scheduler tick, 4 ms) per call of
--   a  the hook that mc.server_tick calls on the player connection:  `if mc.entity_mode() <> 'off' then mc.entity_step(tick)`   (off: just the mode probe;  split: the events of the entity connection)
--   b  the entity tick itself (inline: it IS the hook;  split: what the entity connection runs once per tick, in its own session)
-- Prints one line:  mode players | a us avg p50 min | b us avg p50 min
\set ON_ERROR_STOP on
\timing off
\if :{?players}
\else
\set players 50
\endif
\if :{?ticks}
\else
\set ticks 300
\endif
select set_config('dbcraft.entity_spawner', 'off', false);
update mc.server_property set value = :'mode' where key = 'dbcraft.entity-mode';
truncate mc.play_out, mc.entity_cell_viewer, mc.entity_viewer_cell, mc.entity_tick_log;
delete from mc.entity;
delete from mc.player;
create schema if not exists tickbench;
create or replace function tickbench.sched() returns bigint[] language sql volatile as $$
  select string_to_array(split_part(pg_read_file('/proc/self/schedstat'), E'\n', 1), ' ')::bigint[] $$;
update mc.server_property set value = '10' where key = 'view-distance';
-- players spread over a grid, 40 chunks apart (their views do not overlap), standing still
insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, chunk_x, chunk_z, gamemode)
select gen_random_uuid(), 'p' || i, i, nextval('mc.entity_id_seq'), ((i % 15) * 40) * 16 + 0.5, -60, ((i / 15) * 40) * 16 + 0.5, (i % 15) * 40, (i / 15) * 40, 1 from generate_series(1, :players) i;
create temp table _t (tick int, a float8, b float8);
create procedure pg_temp.run(p_from int, p_to int, p_rec boolean) language plpgsql as $$
declare x timestamptz; y timestamptz; z timestamptz; m text;
begin
    for tk in p_from..p_to loop
        x := clock_timestamp();
        m := mc.entity_mode();
        if m <> 'off' then perform mc.entity_step(tk); end if;
        y := clock_timestamp();
        if m = 'split' then perform mc.entity_tick(tk); end if;
        z := clock_timestamp();
        if p_rec then insert into _t values (tk, extract(epoch from y - x) * 1e6, extract(epoch from z - y) * 1e6); end if;
        commit;
    end loop;
end $$;
call pg_temp.run(1, 40, false);
vacuum analyze mc.entity, mc.entity_lane, mc.entity_viewer_cell, mc.entity_cell_viewer;
call pg_temp.run(41, 40 + :ticks, true);
select format('%s players=%s | a us avg %s p50 %s min %s | b us avg %s p50 %s min %s', :'mode', :players,
              round(avg(a)::numeric), round((percentile_cont(0.5) within group (order by a))::numeric), round(min(a)::numeric),
              round(avg(b)::numeric), round((percentile_cont(0.5) within group (order by b))::numeric), round(min(b)::numeric)) as result from _t;
