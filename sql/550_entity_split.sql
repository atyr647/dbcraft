-- Entity simulation on its own connection: opt-in modes and the ownership rules between the player connection (A) and the entity connection (B).  docs/PERF-MULTICORE.md.
--
--   dbcraft.entity-mode (mc.server_property)
--     off     (default)  nothing: mc.entity_tick() is only called by whoever wants it (tests, benchmarks), exactly as before
--     inline             mc.server_tick() calls mc.entity_tick(cur) itself, after the kicks and before the drain: one connection, one transaction
--     split              the entity tick runs on ANOTHER connection (mc.entity_loop(), tools/entity_loop.sh), once per tick of A, in its own transaction;
--                        A only applies the effects that must be A's (pickups), at the same place of its tick
--
-- OWNERSHIP in split mode (one writer per table; a table is read freely by the other side, reads see the other side's last COMMITTED state):
--   A writes   mc.player, mc.inventory_slot, mc.chunk*, net.*, mc.play_in*, mc.block_event ..., its own mc.play_out rows, mc.entity_cmd (INSERT only), and DELETEs mc.entity_pickup_req
--   B writes   mc.entity, mc.entity_lane, mc.entity_floor, mc.solid_mask, mc.entity_cell_viewer, mc.entity_viewer_cell, mc.entity_tick_log, its own mc.play_out rows (INSERT only),
--              mc.entity_pickup_req (INSERT only), and DELETEs mc.entity_cmd
--   mc.play_out is shared by INSERT: both connections append, only A's drain deletes (A's DELETE ... RETURNING sees the rows committed so far; B's later rows wait for the next tick).
--   Consequently TRUNCATE of mc.play_out (which sql/430 does every 20th tick) is skipped in split mode.
-- Everything A would have changed in B's tables is a COMMAND row instead (mc.entity_cmd): a block change that wakes sleepers and ends lanes (the trigger of sql/541 enqueues 'wake'),
-- the outcome of a pickup ('discard' / 'setcount').  Everything B would have changed in A's tables is a REQUEST row: a pickup (mc.entity_pickup_req).  Commands and requests are applied
-- at the START of the receiver's next tick, in sequence order.
-- Consistency across the one-tick lag: B sees A's state as of A's last commit and A sees B's as of B's last commit, so what one side decides on can be one tick old.
--   * pickup: B finds item + player in range and files the request, and sets the item's pickup_at 20 ticks ahead (nobody else can request it meanwhile).  A grants it
--     against the item row as it is NOW (still there? how many?) and the player's inventory NOW (room?), sends the collector's packets, and files 'discard' or 'setcount'
--     for B; B applies it at its next tick (the other viewers see take_item_entity and the removal then).  A full inventory: nothing happens, the item can be requested again after
--     the 20 ticks (inline mode retries every 4th tick: the one deliberate difference).  An item that despawned in between is simply not granted.
--   * block change: the sleeper wakes / the lane ends in B's tick that follows the change (inline: in the same tick).  With B in lockstep that is the same tick.
--   * B never writes to a player and A never writes to an entity, so no row is ever updated by both.
-- If B OVERRUNS (its tick takes longer than A's interval) mc.entity_loop() does not queue up: when it is more than dbcraft.entity-max-lag (default 5) ticks behind it jumps to the newest
-- tick of A.  Positions are functions of the tick number (lanes, the sweep's catch-up step), so a jump costs smoothness, not correctness; the goal / despawn / pickup cadences that
-- fall into the skipped ticks are simply late.
-- Known limitation: A's trigger on mc.chunk_section (sql/541) deletes the floor summaries and masks that B may be building in the same moment: a row-lock wait of at most one tick
-- of B, a deadlock (aborted by Postgres after deadlock_timeout) only if both sides hit the same chunk at the same time.

insert into mc.server_property (key, value, default_value, note) values
    ('dbcraft.entity-mode', 'off', 'off', 'dbcraft: entity simulation: off | inline (mc.server_tick calls mc.entity_tick) | split (mc.entity_loop() on a second connection); docs/PERF-MULTICORE.md'),
    ('dbcraft.entity-max-lag', '5', '5', 'dbcraft: split mode: ticks the entity connection may be behind before it jumps to the newest tick')
on conflict (key) do nothing;

create or replace function mc.entity_mode() returns text language plpgsql stable as $$
begin return coalesce(nullif((select value from mc.server_property where key = 'dbcraft.entity-mode'), ''), 'off'); end $$;

-- A -> B
create unlogged table if not exists mc.entity_cmd (
    seq  bigint generated always as identity primary key,
    kind text not null check (kind in ('wake', 'discard', 'setcount')),
    id   int,           -- discard / setcount: the item entity
    peid int,           -- discard: the collector's entity id
    n    int,           -- discard: how many were taken;  setcount: the new count;  wake: the tick of the block change
    dim  text, x int, y int, z int        -- wake: the changed block
);
-- B -> A
create unlogged table if not exists mc.entity_pickup_req (
    seq     bigint generated always as identity primary key,
    tick    bigint not null,
    item_id int not null,
    uuid    uuid not null,
    peid    int not null
);
-- B's own diary: how far behind A it ran and how long each tick took (split mode)
create unlogged table if not exists mc.entity_loop_log (
    tick bigint primary key, a_tick bigint not null, lag int not null, ms float8 not null
);

------------------------------------------------------------------------------------------------ wake-ups (A's block events -> B)
-- the logic of the trigger function of sql/541 on arrays of changed blocks (with the tick of the change); B runs it at the start of its tick
create or replace function mc.entity_wake_apply(p_dim text[], p_x int[], p_y int[], p_z int[], p_tk bigint[]) returns void language plpgsql as $$
declare lt bigint;
begin
    lt := coalesce(nullif(current_setting('dbcraft.entity_tick', true), '')::bigint, (select game_time - 1 from mc.game_state limit 1));      -- the last entity tick (a fresh session: the tick before A's
    update mc.entity e set deep_sleep = false,
           phys_tick = case when e.type = 'minecraft:item' then ev.tk - ((ev.tk - e.born_tick + e.id) % 4) else ev.tk end
      from (select dimension, x, y, z, min(tk) as tk from unnest(p_dim, p_x, p_y, p_z, p_tk) u(dimension, x, y, z, tk) group by 1, 2, 3, 4) ev
     where e.deep_sleep and e.dimension = ev.dimension
       and e.cx in ((ev.x - 1) >> 4, ev.x >> 4, (ev.x + 1) >> 4) and e.cz in ((ev.z - 1) >> 4, ev.z >> 4, (ev.z + 1) >> 4)
       and abs(floor(e.x)::int - ev.x) <= 1 and abs(floor(e.z)::int - ev.z) <= 1 and floor(e.y)::int - ev.y between -1 and 2;
    with u as (update mc.entity e set x = e.x + e.gx * greatest(lt - e.phys_tick, 0), z = e.z + e.gz * greatest(lt - e.phys_tick, 0), phys_tick = greatest(lt, e.phys_tick), lane_until = 0,
                      cx = floor((e.x + e.gx * greatest(lt - e.phys_tick, 0)) / 16)::int, cz = floor((e.z + e.gz * greatest(lt - e.phys_tick, 0)) / 16)::int,
                      sent_qx = l0.sqx, sent_qy = l0.sqy, sent_qz = l0.sqz, sent_yaw = l0.syaw, last_sent_tick = l0.last_tick
                 from (select distinct dimension, x >> 4 as ecx, z >> 4 as ecz from unnest(p_dim, p_x, p_y, p_z) u(dimension, x, y, z)) ev, mc.entity_lane l0
                where l0.id = e.id and e.lane_until > 0 and e.dimension = ev.dimension and e.cx between ev.ecx - 2 and ev.ecx + 2 and e.cz between ev.ecz - 2 and ev.ecz + 2 returning e.id)
    delete from mc.entity_lane l using u where l.id = u.id;
end $$;

------------------------------------------------------------------------------------------------ the trigger: in split mode a command instead of an UPDATE of B's rows

create or replace function mc.entity_wake_on_block_event() returns trigger language plpgsql as $$
declare t bigint; lt bigint;
begin
    if mc.entity_mode() = 'split' then          -- the entities belong to the other connection: tell it instead of touching its rows
        insert into mc.entity_cmd (kind, n, dim, x, y, z) select 'wake', (select game_time from mc.game_state limit 1), ev.dimension, ev.x, ev.y, ev.z from (select distinct dimension, x, y, z from new_ev) ev;
        return null;
    end if;
    select game_time into t from mc.game_state limit 1;
    lt := coalesce(nullif(current_setting('dbcraft.entity_tick', true), '')::bigint, t);          -- the last entity tick: lane rows are valid for the state after it
    update mc.entity e set deep_sleep = false,
           phys_tick = case when e.type = 'minecraft:item' then t - ((t - e.born_tick + e.id) % 4) else t end
      from (select distinct dimension, x, y, z from new_ev) ev
     where e.deep_sleep and e.dimension = ev.dimension
       and e.cx in ((ev.x - 1) >> 4, ev.x >> 4, (ev.x + 1) >> 4) and e.cz in ((ev.z - 1) >> 4, ev.z >> 4, (ev.z + 1) >> 4)
       and abs(floor(e.x)::int - ev.x) <= 1 and abs(floor(e.z)::int - ev.z) <= 1 and floor(e.y)::int - ev.y between -1 and 2;
    -- lanes: everything with a lane in the chunks around the event (a lane can be up to a goal long, about 11 blocks, so one chunk of margin is enough)
    with u as (update mc.entity e set x = e.x + e.gx * greatest(lt - e.phys_tick, 0), z = e.z + e.gz * greatest(lt - e.phys_tick, 0), phys_tick = greatest(lt, e.phys_tick), lane_until = 0,
                      cx = floor((e.x + e.gx * greatest(lt - e.phys_tick, 0)) / 16)::int, cz = floor((e.z + e.gz * greatest(lt - e.phys_tick, 0)) / 16)::int,
                      sent_qx = l0.sqx, sent_qy = l0.sqy, sent_qz = l0.sqz, sent_yaw = l0.syaw, last_sent_tick = l0.last_tick
                 from (select distinct dimension, x >> 4 as ecx, z >> 4 as ecz from new_ev) ev, mc.entity_lane l0
                where l0.id = e.id and e.lane_until > 0 and e.dimension = ev.dimension and e.cx between ev.ecx - 2 and ev.ecx + 2 and e.cz between ev.ecz - 2 and ev.ecz + 2 returning e.id)
    delete from mc.entity_lane l using u where l.id = u.id;
    return null;
end $$;

------------------------------------------------------------------------------------------------ B applies A's commands
create or replace function mc.entity_cmd_apply(p_tick bigint) returns int language plpgsql volatile as $$
declare r record; n int := 0; wd text[] := '{}'; wx int[] := '{}'; wy int[] := '{}'; wz int[] := '{}'; wt bigint[] := '{}';
        ids int[] := '{}'; peids int[] := '{}'; cnts int[] := '{}';
begin
    for r in with d as (delete from mc.entity_cmd returning *) select * from d order by seq loop
        n := n + 1;
        if r.kind = 'wake' then wd := wd || r.dim; wx := wx || r.x; wy := wy || r.y; wz := wz || r.z; wt := wt || r.n::bigint;
        elsif r.kind = 'setcount' then update mc.entity set data = jsonb_set(data, '{count}', to_jsonb(r.n)) where id = r.id;
        elsif r.kind = 'discard' then ids := ids || r.id; peids := peids || r.peid; cnts := cnts || r.n;
        end if;
    end loop;
    if n = 0 then return 0; end if;
    if cardinality(wd) > 0 then perform mc.entity_wake_apply(wd, wx, wy, wz, wt); end if;
    if cardinality(ids) > 0 then
        -- the other viewers of the item see it fly to the collector (the collector was told by A), then the item disappears (what mc.entity_pickup of sql/520 does in one go)
        insert into mc.play_out (conn_id, data)
        select v.conn_id, string_agg(mc.cb('take_item_entity', proto.varint(u.eid) || proto.varint(u.peid) || proto.varint(u.cnt)), '\x'::bytea order by u.eid)
          from unnest(ids, peids, cnts) u(eid, peid, cnt) join mc.entity e on e.id = u.eid
          join mc.entity_cell_viewer v on v.cx = e.cx and v.cz = e.cz
          join mc.entity_viewer_cell vc on vc.conn_id = v.conn_id and greatest(abs(vc.cx - e.cx), abs(vc.cz - e.cz)) <= 6
         where e.last_sent_tick > 0 and v.conn_id not in (select pl.conn_id from mc.player pl where pl.entity_id = u.peid and pl.conn_id is not null)
         group by v.conn_id order by v.conn_id;
        perform mc.entity_discard(ids);
    end if;
    return n;
end $$;

------------------------------------------------------------------------------------------------ pickup: B finds, A grants
-- the scan of mc.entity_pickup (sql/520) with the effects replaced by a request; in the other modes it IS mc.entity_pickup
create or replace function mc.entity_pickup_dispatch(p_tick bigint) returns int language plpgsql volatile as $$
declare n int;
begin
    if mc.entity_mode() <> 'split' then return mc.entity_pickup(p_tick); end if;
    with c as (
        select distinct on (e.id) e.id as eid, pl.uuid, pl.entity_id as peid
          from mc.player pl
          cross join lateral generate_series(-1, 1) dx cross join lateral generate_series(-1, 1) dz
          join mc.entity e on e.cx = pl.chunk_x + dx and e.cz = pl.chunk_z + dz
         where pl.conn_id is not null and (pl.entity_id + p_tick) % 4 = 0
           and e.type = 'minecraft:item' and e.pickup_at <= p_tick and pl.gamemode <> 3
           and abs(e.x - pl.x) <= 0.3 + 1.0 + 0.125 and abs(e.z - pl.z) <= 0.3 + 1.0 + 0.125 and e.y + 0.25 >= pl.y - 0.5 and e.y <= pl.y + 1.8 + 0.5
         order by e.id, pl.entity_id),
    rq as (insert into mc.entity_pickup_req (tick, item_id, uuid, peid) select p_tick, c.eid, c.uuid, c.peid from c order by c.eid returning item_id)
    update mc.entity e set pickup_at = p_tick + 20 from rq where e.id = rq.item_id;
    get diagnostics n = row_count;
    return n;
end $$;

-- A: grant the requests against the CURRENT item row and inventory (same packets as sql/520: the collector gets take_item_entity and its slot updates)
create or replace function mc.entity_apply_events(p_tick bigint) returns int language plpgsql volatile as $$
declare r record; dat jsonb; rest int; taken int; st int; cnt int; pl record; n int := 0;
begin
    for r in with d as (delete from mc.entity_pickup_req returning *) select * from d order by seq loop
        select e.data into dat from mc.entity e where e.id = r.item_id and e.type = 'minecraft:item';
        continue when not found;                                                  -- despawned or taken since
        select p.uuid, p.conn_id, p.entity_id into pl from mc.player p where p.uuid = r.uuid and p.conn_id is not null;
        continue when not found;                                                  -- left since
        cnt := (dat ->> 'count')::int;
        rest := mc.inv_add(r.uuid, dat ->> 'item', cnt);
        taken := cnt - rest;
        continue when taken <= 0;
        update mc.player set inv_state = inv_state + 1 where uuid = r.uuid returning inv_state into st;
        insert into mc.play_out (conn_id, data)
        select pl.conn_id, mc.cb('take_item_entity', proto.varint(r.item_id) || proto.varint(pl.entity_id) || proto.varint(taken))
               || (select string_agg(mc.pkt_container_set_slot(st, i.slot, i.item, i.count), '\x'::bytea order by i.slot) from mc.inventory_slot i where i.player = r.uuid and i.item = dat ->> 'item');
        if rest = 0 then insert into mc.entity_cmd (kind, id, peid, n) values ('discard', r.item_id, pl.entity_id, taken);
        else insert into mc.entity_cmd (kind, id, n) values ('setcount', r.item_id, rest); end if;
        n := n + 1;
    end loop;
    return n;
end $$;

-- the hook of mc.server_tick / mc.server_tick_batched (A): inline runs the entity tick, split applies B's requests; an error is logged, never fatal for the tick
create or replace function mc.entity_step(p_tick bigint) returns void language plpgsql volatile as $$
declare m text := mc.entity_mode();
begin
    if m = 'inline' then perform mc.entity_tick(p_tick);
    elsif m = 'split' then perform mc.entity_apply_events(p_tick);
    end if;
exception when others then
    insert into mc.error_log (tick, step, message) values (p_tick, 'entity_step', sqlerrm);
    raise warning 'mc.entity_step failed: %', sqlerrm;
end $$;

------------------------------------------------------------------------------------------------ the entity tick (sql/541's) with the two split-mode hooks

create or replace function mc.entity_tick(p_tick bigint default null) returns int language plpgsql volatile as $$
declare t bigint := coalesce(p_tick, (select game_time from mc.game_state limit 1), 0); ids int[]; lids int[] := '{}'; fl int[] := '{}'; ai int[];
        t0 timestamptz := clock_timestamp(); t1 timestamptz; t2 timestamptz; t3 timestamptz; t4 timestamptz; nsent int; npick int; lanes boolean := mc.entity_lanes_enabled();
begin
    if coalesce(current_setting('dbcraft.entity_impl', true), '') = 'proto' then return mc.entity_tick_proto(t); end if;       -- the original prototype (tests/bench/entity/proto_baseline.sql), for comparison only
    if mc.entity_mode() = 'split' then perform mc.entity_cmd_apply(t); end if;      -- what the player connection asked for since the last tick (BEFORE the tick number moves: wake-ups use the last tick as their lane time)
    perform set_config('dbcraft.entity_tick', t::text, false);
    perform mc.entity_viewers_refresh(t);
    if lanes then fl := mc.entity_lane_flush(t); else perform mc.entity_lane_flush_all(t); end if;
    ai := mc.entity_ai_ids(t);
    if coalesce(current_setting('dbcraft.entity_spawner', true), 'on') <> 'off' then perform mc.entity_spawner(t); end if;
    perform mc.entity_despawn(t);
    if lanes then
        perform mc.entity_lane_try(t, fl || ai);                  -- goal just given: walk on in a lane if the footprint is clean (no sweep this tick)
        lids := mc.entity_lane_step(t);                         -- lean tracker for lane mobs: plain packets built here, a position sync (rare) comes back for the generic tracker
    end if;
    t1 := clock_timestamp();
    ids := mc.entity_physics_ids(t);
    t2 := clock_timestamp();
    nsent := mc.entity_tracker(t, ids || lids);
    -- landed, just placed, or back from a position sync: may (re)start a lane.  AFTER the tracker: a lane copies what the viewers were last told, and this tick's packet is part of it
    -- (started before it, the lane's delta base would be one packet behind the viewers: found by tests/sql/541 E, a constant offset of that packet's delta).
    if lanes then perform mc.entity_lane_try(t, ids || lids); end if;
    t3 := clock_timestamp();
    npick := mc.entity_pickup_dispatch(t);
    t4 := clock_timestamp();
    insert into mc.entity_tick_log (tick, awake, moved, sent, packets, ms_physics, ms_ai, ms_tracker, ms_pickup, ms_total)
    values (t, cardinality(ids) + cardinality(lids) + (select count(*)::int from mc.entity_lane), nsent, nsent, 0, extract(epoch from t2 - t1) * 1000, extract(epoch from t1 - t0) * 1000, extract(epoch from t3 - t2) * 1000, extract(epoch from t4 - t3) * 1000, extract(epoch from t4 - t0) * 1000)
    on conflict (tick) do update set awake = excluded.awake, moved = excluded.moved, sent = excluded.sent, packets = excluded.packets, ms_physics = excluded.ms_physics, ms_ai = excluded.ms_ai,
                                     ms_tracker = excluded.ms_tracker, ms_pickup = excluded.ms_pickup, ms_total = excluded.ms_total;
    return cardinality(ids) + cardinality(lids);
end $$;

------------------------------------------------------------------------------------------------ B's loop
-- call mc.entity_loop();      on its own connection (tools/entity_loop.sh).  One entity tick per tick of A, each in its own transaction (COMMIT per iteration: the new rows are visible
-- to A, and no snapshot is held while it waits).  p_ticks > 0: stop after that many ticks (tests and benchmarks).  Follows mc.game_state.game_time; see the header on overruns.
create or replace procedure mc.entity_loop(p_ticks int default 0, p_idle_ms int default 1) language plpgsql as $$
declare last_t bigint; cur bigint; maxlag int; n int := 0; t0 timestamptz; lag int;
begin
    select game_time into last_t from mc.game_state;
    commit;
    loop
        select game_time into cur from mc.game_state;
        maxlag := coalesce(nullif((select value from mc.server_property where key = 'dbcraft.entity-max-lag'), '')::int, 5);
        if cur > last_t then
            if cur - last_t > maxlag then last_t := cur - 1; end if;               -- overrun: jump to A's newest tick (no queue builds up)
            last_t := last_t + 1;
            lag := (cur - last_t)::int;
            t0 := clock_timestamp();
            begin
                perform mc.entity_tick(last_t);
            exception when others then
                insert into mc.error_log (tick, step, message) values (last_t, 'entity_loop', sqlerrm);
                raise warning 'mc.entity_loop: tick % failed: %', last_t, sqlerrm;
            end;
            insert into mc.entity_loop_log (tick, a_tick, lag, ms) values (last_t, cur, lag, extract(epoch from clock_timestamp() - t0) * 1000) on conflict (tick) do nothing;
            if last_t % 1000 = 0 then delete from mc.entity_loop_log where tick < last_t - 6000; end if;
            commit;
            n := n + 1;
            exit when p_ticks > 0 and n >= p_ticks;
        else
            commit;
            perform pg_sleep(greatest(p_idle_ms, 1) / 1000.0);
        end if;
    end loop;
end $$;
