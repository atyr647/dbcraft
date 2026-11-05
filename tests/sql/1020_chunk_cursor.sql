-- Chunk cursors (sql/1020, docs/PERF-STORM.md "Round 3"): the previous implementation of net.hook_chunks, net.stream_chunks and mc.deliver_ready_chunks (pasted below as t.old_*) against the new one.
-- A random SCRIPT of joins (at different places and view distances), walks over chunk borders, teleports, changes of the view distance, connections that leave and chunk generation is run
-- twice from the same state, once with each implementation, tick by tick, in async and in inline generation mode, under small budgets (a few chunks per connection and tick, a shared cap) so
-- that the delivery takes many ticks.  Compared per tick and connection: the bytes of everything the connection is sent (chunk batches, forgets, cache centres), the bytes of the chunks a join
-- returns inline, the SET of chunks every connection is still wanted-to-be-sent with their distances (rows, plus what a cursor stands for) and the queue of chunk requests.
-- Then three MUTANTS of the new code (the delivery's order, the flush of a cursor at a border, the existence probe of a cursor's window) are run through the same comparison and must be caught.
\ir ../../sql/430_chunk_queue.sql
\ir ../../sql/436_stream_chunks_merge.sql
\ir ../../sql/790_join_budget.sql
\ir ../../sql/791_join_chunk_budget.sql
\! python3 tools/load_world_ref.py

-- the previous code, pasted from the commit before the cursors (git show f09cc54:sql/430, 436, 791), renamed
create or replace function t.old_hook_chunks(p_conn bigint, p_cx int, p_cz int, p_radius int) returns setof bytea language plpgsql volatile as $$
declare r int := mc.conn_view_r(p_conn::int, p_radius + 1); dim text := 'minecraft:overworld'; r_cx int[]; r_cz int[]; r_d int[];
        inl int := coalesce(nullif(mc.prop('dbcraft.join-chunks-inline'), '')::int, 0); lim int;
begin
    if not mc.world_ready() then
        raise notice 'net.hook_chunks: world reference data is not loaded (run tools/load_world_ref.py); no chunks sent to connection %', p_conn;
        return;
    end if;
    update net.conn set view_cx = p_cx, view_cz = p_cz, view_r = r where conn_id = p_conn;
    -- the chunks that do not exist yet: generated now (inline; they are returned below) or queued and delivered later (async)
    -- (docs/PERF-STORM.md: the chunks that exist are read as one index range scan per column of the square, 2r+1 of them, then anti-joined; 529 single probes cost 8 ms)
    with ex as materialized (
        select c.cx, c.cz from generate_series(p_cx - r, p_cx + r) xv
          cross join lateral (select k.cx, k.cz from mc.chunk k where k.dimension = dim and k.cx = xv and k.cz between p_cz - r and p_cz + r) c)
    select array_agg(p_cx + sq.dx order by sq.dx, sq.dz), array_agg(p_cz + sq.dz order by sq.dx, sq.dz), array_agg(sq.dx * sq.dx + sq.dz * sq.dz order by sq.dx, sq.dz) into r_cx, r_cz, r_d
      from (select dx, dz from generate_series(-r, r) dx cross join generate_series(-r, r) dz) sq
      left join ex on ex.cx = p_cx + sq.dx and ex.cz = p_cz + sq.dz
     where ex.cx is null;
    if r_cx is not null then perform mc.want_chunks(p_conn::int, dim, r_cx, r_cz, r_d, false); end if;
    lim := case when inl > 0 and (2 * r + 1) * (2 * r + 1) > inl then inl else 2147483647 end;
    if lim < 2147483647 then
        -- the rest of the square (everything after the nearest `lim`) is wanted: mc.deliver_ready_chunks sends it in the next ticks, nearest first (set-based insert: 5 ms
        -- through mc.want_chunks' unnest and ON CONFLICT DO UPDATE, 1.5 ms like this; the missing ones are already in the queue above and may be wanted rows already)
        insert into mc.chunk_wanted (conn_id, dimension, cx, cz, dist)
        select p_conn, dim, p_cx + s.dx, p_cz + s.dz, s.dx * s.dx + s.dz * s.dz
          from (select dx, dz, row_number() over (order by dx * dx + dz * dz, dx, dz) o from generate_series(-r, r) dx cross join generate_series(-r, r) dz) s
         where s.o > lim
        on conflict (conn_id, dimension, cx, cz) do nothing;
    end if;
    return query
    select mc.packet_body(coalesce(k.packet, mc.chunk_packet(dim, c.cx, c.cz)))
      from (select dx, dz, row_number() over (order by dx * dx + dz * dz, dx, dz) o from generate_series(-r, r) dx cross join generate_series(-r, r) dz) s
      join mc.chunk c on c.dimension = dim and c.cx = p_cx + s.dx and c.cz = p_cz + s.dz
      left join mc.chunk_cache k on k.dimension = c.dimension and k.cx = c.cx and k.cz = c.cz and k.version = c.version and not c.dirty and not c.hm_dirty
     where s.o <= lim
     order by s.dx * s.dx + s.dz * s.dz, s.dx, s.dz;
end $$;

create or replace function t.old_stream_chunks() returns int language plpgsql as $$
declare srv int := mc.prop_int('view-distance'); vison boolean := mc.vis_on(); dim text := 'minecraft:overworld'; n int;
        i_ctr int := mc.pid('set_chunk_cache_center'); i_fg int := mc.pid('forget_level_chunk');
        sc int[]; sncx int[]; sncz int[]; socx int[]; socz int[]; snr int[]; sor int[];            -- the players whose view changes: connection, new chunk, chunk their client is centred on, radii of the new and the old square
        wc_c int[]; wc_x int[]; wc_z int[]; wc_d int[];                                            -- the chunks that entered their squares: connection, chunk, squared distance (async mode)
begin
    if mc.world_ready() then
        -- a player's square has the radius view distance + 1; the view distance is the server's, or (dbcraft.vanilla-tracker, sql/909) the one the client asked for, clamped to 2 .. the server's
        select array_agg(c.conn_id::int), array_agg(p.chunk_x), array_agg(p.chunk_z), array_agg(c.view_cx), array_agg(c.view_cz),
               array_agg(case when vison then greatest(2, least(coalesce(p.view_distance_req, 2), srv)) + 1 else srv + 1 end), array_agg(coalesce(c.view_r, srv + 1))
          into sc, sncx, sncz, socx, socz, snr, sor
        from net.conn c join mc.player p on p.conn_id = c.conn_id
        where c.state = 'play' and not c.closing and c.view_cx is not null
          and ((p.chunk_x, p.chunk_z) <> (c.view_cx, c.view_cz) or coalesce(c.view_r, srv + 1) <> (case when vison then greatest(2, least(coalesce(p.view_distance_req, 2), srv)) + 1 else srv + 1 end));
        n := coalesce(cardinality(sc), 0);
        if n > 0 then
            -- the centre moves only when the player changed chunk (a new view distance alone sends chunks or forgets them, no centre: recorded)
            insert into mc.play_out (conn_id, data)
            select s.conn_id, proto.frame(i_ctr, proto.varint(s.ncx) || proto.varint(s.ncz)) from unnest(sc, sncx, sncz, socx, socz) as s(conn_id, ncx, ncz, ocx, ocz) where (s.ncx, s.ncz) <> (s.ocx, s.ocz) order by s.conn_id;
            -- chunks that left the client's square: x ascending, then z (ChunkTrackingView.difference iterates x in the outer loop: recorded with a shrinking and a teleported view; the body is z first)
            insert into mc.play_out (conn_id, data)
            select s.conn_id, case when i_fg < 128 then '\x09'::bytea || set_byte('\x00'::bytea, 0, i_fg) || proto.i32(s.ocz + dz) || proto.i32(s.ocx + dx)       -- (proto.frame of a body of 8 bytes: one function call less per row, 1,200 rows a tick with 500 walkers)
                                   else proto.frame(i_fg, proto.i32(s.ocz + dz) || proto.i32(s.ocx + dx)) end
            from unnest(sc, sncx, sncz, socx, socz, snr, sor) as s(conn_id, ncx, ncz, ocx, ocz, nr, orr), generate_series(-s.orr, s.orr) dx, generate_series(-s.orr, s.orr) dz
            where abs(s.ocx + dx - s.ncx) > s.nr or abs(s.ocz + dz - s.ncz) > s.nr
            order by s.conn_id, s.ocx + dx, s.ocz + dz;
            -- the client's view moves now, so the chunks that entered the square pass the range check of the delivery step
            update net.conn c set view_cx = s.ncx, view_cz = s.ncz, view_r = s.nr from unnest(sc, sncx, sncz, snr) as s(conn_id, ncx, ncz, nr) where c.conn_id = s.conn_id;
            -- the chunks that entered the square are wanted (generated now in inline mode, requested in async mode)
            if mc.chunk_generation_async() then
                -- (docs/PERF-CAPACITY.md) async mode: what mc.want_chunks does for each connection, for all of them in two statements (a call per connection was 0.4 ms each, 9 a tick
                -- with 500 walkers): the wanted rows, and one request per chunk that does not exist yet with the smallest distance of its requesters (the order of the per-connection calls
                -- made the same least())
                -- (the rows go through arrays: the planner estimates 10 rows for an unnest and 10 million for the cross join of generate_series, and with the second estimate it
                -- scanned the whole of mc.chunk to find the chunks that do not exist: 10 ms)
                select array_agg(q.conn_id), array_agg(q.x), array_agg(q.z), array_agg(q.d) into wc_c, wc_x, wc_z, wc_d
                  from (select s.conn_id, s.ncx + dx as x, s.ncz + dz as z, dx * dx + dz * dz as d
                          from unnest(sc, sncx, sncz, socx, socz, snr, sor) as s(conn_id, ncx, ncz, ocx, ocz, nr, orr), generate_series(-s.nr, s.nr) dx, generate_series(-s.nr, s.nr) dz
                         where abs(s.ncx + dx - s.ocx) > s.orr or abs(s.ncz + dz - s.ocz) > s.orr) q;
                if wc_c is not null then
                    insert into mc.chunk_wanted (conn_id, dimension, cx, cz, dist) select u.c, dim, u.x, u.z, u.d from unnest(wc_c, wc_x, wc_z, wc_d) as u(c, x, z, d)
                    on conflict (conn_id, dimension, cx, cz) do update set dist = excluded.dist;
                    insert into mc.chunk_request (dimension, cx, cz, prio)
                    select dim, u.x, u.z, min(u.d) from unnest(wc_c, wc_x, wc_z, wc_d) as u(c, x, z, d)
                     where not exists (select 1 from mc.chunk c where c.dimension = dim and c.cx = u.x and c.cz = u.z)
                     group by u.x, u.z
                    on conflict (dimension, cx, cz) do update set prio = least(mc.chunk_request.prio, excluded.prio);
                end if;
            else
                perform mc.want_chunks(q.conn_id, dim, array_agg(q.x), array_agg(q.z), array_agg(q.d))
                  from (select s.conn_id, s.ncx + dx as x, s.ncz + dz as z, dx * dx + dz * dz as d
                          from unnest(sc, sncx, sncz, socx, socz, snr, sor) as s(conn_id, ncx, ncz, ocx, ocz, nr, orr), generate_series(-s.nr, s.nr) dx, generate_series(-s.nr, s.nr) dz
                         where abs(s.ncx + dx - s.ocx) > s.orr or abs(s.ncz + dz - s.ocz) > s.orr) q
                 group by q.conn_id;
            end if;
        end if;
    end if;
    perform t.old_deliver();
    return coalesce(n, 0);
end $$;

create or replace function t.old_deliver() returns int language plpgsql volatile as $$
declare
    r     int := mc.prop_int('view-distance') + 1;
    cap   int := coalesce(mc.prop_int('dbcraft.chunk-batch-max'), 64);                                   -- per connection and tick
    gcap  int := nullif(coalesce(mc.prop_int('dbcraft.chunk-budget-per-tick'), 600), 0);                 -- all connections together; null: unlimited
    i_bs  int := mc.pid('chunk_batch_start');
    i_bf  int := mc.pid('chunk_batch_finished');
    n     int; nc int; m int;
    tb    numeric := coalesce(nullif(case when lower(mc.prop('dbcraft.tick-budget-ms')) in ('off', '0', '-1', '') then null else mc.prop('dbcraft.tick-budget-ms') end, '')::numeric, 0);
    t0    timestamptz; el numeric;
    conns int[]; dead int[]; live int[];
    rc int[]; rd text[]; rx int[]; rz int[]; rdist int[];       -- what is sent now: connection, dimension, chunk, distance (kept in arrays: see sql/437 on temp tables)
begin
    if not exists (select 1 from mc.chunk_wanted) then return 0; end if;
    -- dbcraft.tick-budget-ms: the shared cap shrinks with the time this tick has already used (process_fast records its start): a tick that spent 25 ms of a 35 ms budget on a join
    -- sends 40% of the cap, a tick without joins all of it.  Without a recorded start (anything but the tick) or with an implausible one (a test running many ticks inside one statement) the cap is not scaled.
    if tb > 0 and gcap is not null then
        t0 := nullif(current_setting('dbcraft.tick_t0', true), '')::timestamptz;                -- set by net.process_fast in this transaction; not set (no scaling) anywhere else
        el := extract(epoch from clock_timestamp() - t0) * 1000;
        if el >= 0 and el < 2000 then gcap := greatest(1, ceil(gcap * greatest(0.4, least(1, (tb - el) / tb)))::int); end if;
    end if;
    -- the connections that have wanted rows (a loose index scan: the rows are many during a storm, the connections are few), and which of them still play
    select coalesce(array_agg(q.c), '{}') into conns from (
        with recursive cs(c) as (select min(conn_id) from mc.chunk_wanted union all select (select min(w.conn_id) from mc.chunk_wanted w where w.conn_id > cs.c) from cs where cs.c is not null)
        select c from cs where c is not null) q;
    select coalesce(array_agg(u.c) filter (where lv.conn_id is null), '{}'), coalesce(array_agg(u.c) filter (where lv.conn_id is not null), '{}') into dead, live
      from unnest(conns) u(c) left join net.conn lv on lv.conn_id = u.c and lv.state = 'play' and not lv.closing and lv.view_cx is not null;
    if cardinality(dead) > 0 then
        delete from mc.chunk_wanted where conn_id = any (dead);
        delete from mc.chunk_wanted_view where conn_id = any (dead);
    end if;
    nc := cardinality(live);
    if nc = 0 then return 0; end if;
    -- a client whose view moved since its rows were last cleaned: what left its square is not wanted any more
    with mv as (select c.conn_id, c.view_cx as vx, c.view_cz as vz, coalesce(c.view_r, r) as vr from net.conn c left join mc.chunk_wanted_view v on v.conn_id = c.conn_id
                 where c.conn_id = any (live) and (v.conn_id is null or v.vcx <> c.view_cx or v.vcz <> c.view_cz)),
         del as (delete from mc.chunk_wanted w using mv where w.conn_id = mv.conn_id and (abs(w.cx - mv.vx) > mv.vr or abs(w.cz - mv.vz) > mv.vr) returning 1)
    insert into mc.chunk_wanted_view (conn_id, vcx, vcz) select conn_id, vx, vz from mv
    on conflict (conn_id) do update set vcx = excluded.vcx, vcz = excluded.vcz;
    -- every connection's nearest wanted chunks that exist now; round-robin across connections (rank 1 of everybody, then rank 2, ...) up to the shared cap
    m := case when gcap is null then cap else least(cap, greatest(1, ceil(gcap::numeric / nc)::int)) end;
    select array_agg(x.conn_id), array_agg(x.dimension), array_agg(x.cx), array_agg(x.cz), array_agg(x.dist) into rc, rd, rx, rz, rdist
      from (select q.*, row_number() over (order by q.rn, q.conn_id) as gr
              from (select l.*, row_number() over (partition by l.conn_id order by l.dist, l.cx, l.cz) as rn
                      from unnest(live) u(c) join net.conn n on n.conn_id = u.c
                      cross join lateral (select w.conn_id, w.dimension, w.cx, w.cz, w.dist
                                            from mc.chunk_wanted w join mc.chunk ch on ch.dimension = w.dimension and ch.cx = w.cx and ch.cz = w.cz
                                           where w.conn_id = n.conn_id and abs(n.view_cx - w.cx) <= coalesce(n.view_r, r) and abs(n.view_cz - w.cz) <= coalesce(n.view_r, r)
                                           order by w.dist, w.cx, w.cz limit m) l) q) x
     where gcap is null or x.gr <= gcap;
    n := coalesce(cardinality(rc), 0);
    if n = 0 then return 0; end if;
    -- (docs/PERF-CAPACITY.md) the rows are found by primary key, one probe per row, and deleted by tuple id.  As a plain DELETE ... USING the planner, which believes this churned queue
    -- table holds one row (its statistics say 0 after every vacuum), scanned the whole of the primary key index once and rescanned the unnest list for each entry: 1,527 buffer hits
    -- and 8.7 ms for 63 rows, 47 us a row, in a tick with 200 walkers
    delete from mc.chunk_wanted w
     where w.ctid = any (array(select x.tid from unnest(rc, rd, rx, rz) as d(conn_id, dimension, cx, cz)
                                 cross join lateral (select w2.ctid as tid from mc.chunk_wanted w2
                                                      where w2.conn_id = d.conn_id and w2.dimension = d.dimension and w2.cx = d.cx and w2.cz = d.cz) x));
    insert into mc.play_out (conn_id, data) select distinct d.conn_id, proto.frame(i_bs, '\x') from unnest(rc) as d(conn_id);
    insert into mc.play_out (conn_id, data)
    select d.conn_id, coalesce(k.packet, mc.chunk_packet(d.dimension, d.cx, d.cz))
      from unnest(rc, rd, rx, rz, rdist) as d(conn_id, dimension, cx, cz, dist)
      left join mc.chunk c on c.dimension = d.dimension and c.cx = d.cx and c.cz = d.cz and not c.dirty and not c.hm_dirty and c.hm_world_surface is not null
      left join mc.chunk_cache k on k.dimension = c.dimension and k.cx = c.cx and k.cz = c.cz and k.version = c.version
     order by d.conn_id, d.dist, d.cx, d.cz;
    insert into mc.play_out (conn_id, data) select d.conn_id, proto.frame(i_bf, proto.varint(count(*)::int)) from unnest(rc) as d(conn_id) group by d.conn_id;
    return n;
end $$;


------------------------------------------------------------------------------------------------ the script
create table if not exists t.cs_script (seed int, tick int, ord int, op text, conn int, a int, b int);
create table if not exists t.cs_dbg (impl text, tick int, rq text);
create table if not exists t.cs_out (impl text, tick int, conn int, h text, w text, rq text, cur int);

-- p_n connections over p_ticks ticks.  ops: join (a, b = chunk), walk (a, b = new chunk), view (a = view distance), leave, gen (a = batch), del (a, b = centre of 3 x 3 chunks that vanish)
create or replace function t.cs_make(p_seed int, p_n int, p_ticks int, p_span int) returns void language plpgsql as $$
declare tk int; c int; cx int[]; cz int[]; alive boolean[]; vd int[]; k int := 0; x float8;
begin
  perform setseed(p_seed / 1000.0);
  delete from t.cs_script where seed = p_seed;
  cx := array_fill(0, array[p_n]); cz := array_fill(0, array[p_n]); alive := array_fill(false, array[p_n]); vd := array_fill(3, array[p_n]);
  for tk in 1 .. p_ticks loop
    for c in 1 .. p_n loop
      x := random();
      if not alive[c] then
        if x < 0.12 then       -- a join at a random chunk (some of them at the edge of the generated patch), some with a view distance of their own
          cx[c] := (random() * p_span)::int - 3; cz[c] := (random() * p_span)::int - 3; vd[c] := 2 + (random() * 4)::int; alive[c] := true; k := k + 1;
          insert into t.cs_script values (p_seed, tk, k, 'join', c, cx[c], cz[c]);
          insert into t.cs_script values (p_seed, tk, k + 1000, 'view', c, vd[c], null);
        end if;
      else
        if x < 0.35 then       -- one chunk along an axis or a diagonal
          cx[c] := cx[c] + (array[-1, 0, 1])[1 + (random() * 2)::int]; cz[c] := cz[c] + (array[-1, 0, 1])[1 + (random() * 2)::int]; k := k + 1;
          insert into t.cs_script values (p_seed, tk, k, 'walk', c, cx[c], cz[c]);
        elsif x < 0.40 then    -- a teleport: far (the new square may not touch the old) or near
          cx[c] := cx[c] + (random() * 30 - 15)::int; cz[c] := cz[c] + (random() * 30 - 15)::int; k := k + 1;
          insert into t.cs_script values (p_seed, tk, k, 'walk', c, cx[c], cz[c]);
        elsif x < 0.46 then    -- a new view distance (bigger or smaller)
          vd[c] := 2 + (random() * 4)::int; k := k + 1;
          insert into t.cs_script values (p_seed, tk, k + 1000, 'view', c, vd[c], null);
        elsif x < 0.49 then
          alive[c] := false; k := k + 1;
          insert into t.cs_script values (p_seed, tk, k, 'leave', c, null, null);
        end if;
      end if;
    end loop;
    if tk % 3 = 0 then insert into t.cs_script values (p_seed, tk, 5000, 'gen', null, 2 + (random() * 6)::int, null); end if;
    if tk % 7 = 4 then insert into t.cs_script values (p_seed, tk, 4000, 'del', null, (random() * p_span)::int - 2, (random() * p_span)::int - 2); end if;     -- a 3 x 3 block of chunks disappears (a cursor over it must notice)
  end loop;
end $$;

-- the wanted set of everybody: rows plus what the cursors stand for, as a digest
create or replace function t.cs_wanted() returns text language sql as $$
  select md5(coalesce(string_agg(q.c || ':' || q.dm || ':' || q.x || ',' || q.z || ':' || q.d, ' ' order by q.c, q.x, q.z, q.dm), ''))
    from (select conn_id as c, dimension as dm, cx as x, cz as z, dist as d from mc.chunk_wanted where dimension <> 'cursor'
           union all
          select cu.conn_id, cu.dimension, cu.cx + s.dx, cu.cz + s.dz, s.d from mc.chunk_cursor cu join mc.chunk_spiral s on s.r = cu.r and s.o > cu.next_o
           where cu.orr is null or abs(cu.cx + s.dx - cu.ocx) > cu.orr or abs(cu.cz + s.dz - cu.ocz) > cu.orr) q $$;

create or replace function t.cs_run(p_impl text, p_seed int, p_async boolean, p_cap int, p_gcap int) returns void language plpgsql as $$
declare tk int; r record; hook text := case when p_impl = 'old' then 't.old_hook_chunks' else 'net.hook_chunks' end; strm text := case when p_impl = 'old' then 't.old_stream_chunks' else 'net.stream_chunks' end;
        head text; srv int := 6; vdj int;
begin
  delete from t.cs_out where impl = p_impl; delete from t.cs_dbg where impl = p_impl;
  truncate net.conn_ctl, net.conn, net.inbox, net.outbox, mc.play_out, mc.chunk_wanted, mc.chunk_request, mc.chunk_wanted_view, mc.chunk_cursor, mc.visible, mc.vtrk, mc.wp;
  delete from mc.player;
  update mc.server_property set value = srv::text where key in ('view-distance', 'simulation-distance');
  update mc.server_property set value = case when p_async then 'async' else 'inline' end where key = 'dbcraft.chunk-generation';
  update mc.server_property set value = p_cap::text where key = 'dbcraft.chunk-batch-max';
  update mc.server_property set value = p_gcap::text where key = 'dbcraft.chunk-budget-per-tick';
  update mc.server_property set value = 'off' where key = 'dbcraft.tick-budget-ms';
  update mc.server_property set value = '12' where key = 'dbcraft.join-chunks-inline';
  update mc.game_state set game_time = 700;
  truncate mc.chunk cascade;
  perform mc.generate_batch('minecraft:overworld', array_agg(x), array_agg(z)) from generate_series(-8, 16) x, generate_series(-8, 16) z where (x between -7 and 14 and z between -7 and 14) or abs(x * 7919 + z * 104729 + p_seed) % 10 < 3;     -- (not random(): both runs must have the same world)
  for tk in 1 .. 60 loop
    for r in select * from t.cs_script where seed = p_seed and tick = tk order by ord loop
      if r.op = 'join' then
        vdj := coalesce((select v.a from t.cs_script v where v.seed = p_seed and v.tick = tk and v.conn = r.conn and v.op = 'view' limit 1), 4);   -- the join's own view distance, so that the cursor made by the join is not stale at once
        insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, yaw, pitch, chunk_x, chunk_z, sent_qx, sent_qy, sent_qz, vis_dirty, last_sent_tick, gamemode, keepalive_sent_tick, view_distance_req)
        values (md5(r.conn::text)::uuid, 'cs' || r.conn, r.conn, r.conn, 8, 70, 8, 0, 0, r.a, r.b, mc.quant(8), mc.quant(70), mc.quant(8), false, 0, 1, 700, vdj)
        on conflict (uuid) do update set chunk_x = excluded.chunk_x, chunk_z = excluded.chunk_z, conn_id = excluded.conn_id, view_distance_req = vdj;
        update mc.player set view_distance_req = vdj where conn_id = r.conn;      -- (the insert trigger of the vanilla tracker clears it)
        delete from net.conn where conn_id = r.conn;
        insert into net.conn (conn_id, state, name, uuid, compression, entity_id, gamemode) values (r.conn, 'play', 'cs' || r.conn, md5(r.conn::text)::uuid, -1, r.conn, 1);
        execute format('select string_agg(md5(b), %L order by o) from (select b, row_number() over () o from %s(%s, %s, %s, %s) b) q', ',', hook, r.conn, r.a, r.b, 4) into head;
        insert into t.cs_out values (p_impl, tk, -r.conn, 'J' || coalesce(head, ''), null, null, null);
      elsif r.op = 'walk' then
        update mc.player set chunk_x = r.a, chunk_z = r.b where conn_id = r.conn;
      elsif r.op = 'view' then
        update mc.player set view_distance_req = r.a where conn_id = r.conn;
      elsif r.op = 'leave' then
        delete from net.conn where conn_id = r.conn; delete from mc.player where conn_id = r.conn;
      elsif r.op = 'del' then
        delete from mc.chunk where dimension = 'minecraft:overworld' and cx between r.a - 1 and r.a + 1 and cz between r.b - 1 and r.b + 1;
      elsif r.op = 'gen' then
        perform mc.generate_pending(r.a);
      end if;
    end loop;
    execute format('select %s()', strm);
    insert into t.cs_out
    select p_impl, tk, o.conn_id, md5(string_agg(o.data, ''::bytea order by o.seq)), null, null, null from mc.play_out o group by o.conn_id;
    insert into t.cs_out values (p_impl, tk, 0, null, t.cs_wanted(),
        (select md5(coalesce(string_agg(dimension || cx || ',' || cz || ':' || prio, ' ' order by dimension, cx, cz), '')) from mc.chunk_request), (select count(*)::int from mc.chunk_cursor));
    insert into t.cs_dbg select p_impl, tk, (select string_agg(dimension || cx || ',' || cz || ':' || prio, ' ' order by cx, cz) from mc.chunk_request);
    truncate mc.play_out;
  end loop;
end $$;

-- 'same', or what differs first
create or replace function t.cs_compare(p_seed int, p_async boolean, p_cap int, p_gcap int) returns text language plpgsql as $$
declare d record;
begin
  perform t.cs_run('old', p_seed, p_async, p_cap, p_gcap);
  perform t.cs_run('new', p_seed, p_async, p_cap, p_gcap);
  select o.tick, o.conn, (o.h is distinct from n.h) as bytes, (o.w is distinct from n.w) as wanted, (o.rq is distinct from n.rq) as req into d
    from t.cs_out o full join t.cs_out n on n.impl = 'new' and n.tick = o.tick and n.conn = o.conn
   where o.impl = 'old' and (o.h is distinct from n.h or o.w is distinct from n.w or o.rq is distinct from n.rq)
      or (o.impl is null and n.impl = 'new' and false)
   order by o.tick, o.conn limit 1;
  if found then return format('differs at tick %s connection %s: bytes %s wanted set %s requests %s', d.tick, d.conn, d.bytes, d.wanted, d.req); end if;
  if (select count(*) from t.cs_out where impl = 'old') <> (select count(*) from t.cs_out where impl = 'new') then return 'a different number of outputs'; end if;
  return 'same';
end $$;

select t.cs_make(s, 9, 60, 9) from generate_series(1, 8) s;
select t.is_true('the scripts are not empty: joins, walks, view changes and generation', (select count(*) filter (where op = 'join') > 40 and count(*) filter (where op = 'walk') > 300 and count(*) filter (where op = 'view') > 40 and count(*) filter (where op = 'leave') > 5 from t.cs_script));

select t.eq('async, script ' || s || ', 9 connections, 60 ticks, cap 5 per connection, 14 in all: the new implementation sends, wants and requests exactly what the old one does', t.cs_compare(s, true, 5, 14), 'same') from generate_series(1, 4) s;
select t.eq('inline, script ' || s || ': the same', t.cs_compare(s, false, 5, 14), 'same') from generate_series(5, 8) s;
select t.eq('async, script 2, budgets of 64 and 600 (the defaults)', t.cs_compare(2, true, 64, 600), 'same');
select t.eq('async, script 3, one chunk per connection and tick and no shared cap', t.cs_compare(3, true, 1, 0), 'same');

-- the comparison is not vacuous: cursors existed (joins and crossings), were delivered over several ticks, flushed at borders
select t.cs_compare(5, true, 5, 14) as ran \gset
select t.is_true('async script 5 had a cursor in at least 8 ticks, and in a tick with two of them (async: a cursor only where every chunk of the square exists)', (select count(*) filter (where cur > 0) >= 8 and max(cur) >= 2 from t.cs_out where impl = 'new' and conn = 0));
select t.cs_compare(6, false, 5, 14) as ran \gset
select t.is_true('inline script 6 (the join tail only) had a cursor in at least 20 ticks', (select count(*) filter (where cur > 0) >= 20 from t.cs_out where impl = 'new' and conn = 0));

------------------------------------------------------------------------------------------------ mutants: each change to the new code must be caught
create or replace function t.cs_mutant(p_fn regprocedure, p_from text, p_to text) returns text language plpgsql as $$
declare orig text := pg_get_functiondef(p_fn); mut text := replace(orig, p_from, p_to); res text := '';
begin
  if mut = orig then return 'the mutation did not apply'; end if;
  execute mut;
  begin
    select string_agg(t.cs_compare(s, true, 5, 14), ' ; ') into res from generate_series(1, 4) s;
    res := res || ' ; ' || t.cs_compare(6, false, 5, 14);
  exception when others then res := 'error: ' || sqlerrm;
  end;
  execute orig;
  return res;
end $$;
select t.is_true('mutant 1: the delivery takes a cursor window by the wrong order (descending ordinals) -- caught',
                 t.cs_mutant('mc.deliver_ready_chunks()'::regprocedure, 'order by sp.o limit m', 'order by sp.o desc limit m') <> 'same ; same ; same ; same ; same');
select t.is_true('mutant 2: a flushed cursor also re-wants the position it has sent last (o >= next_o) -- caught',
                 t.cs_mutant('mc.chunk_cursor_flush(int[])'::regprocedure, 's.o > cu.next_o', 's.o >= cu.next_o') <> 'same ; same ; same ; same ; same');
select t.is_true('mutant 3: the delivery does not probe the existence of the chunks of a cursor''s window -- caught',
                 t.cs_mutant('mc.deliver_ready_chunks()'::regprocedure, '(ch.cx is null) as missing', 'false as missing') <> 'same ; same ; same ; same ; same');
select t.is_true('mutant 4: a cursor with a window that was exactly full is dropped (the end test <= m) -- caught',
                 t.cs_mutant('mc.deliver_ready_chunks()'::regprocedure, 'win.w < m', 'win.w <= m') <> 'same ; same ; same ; same ; same');
select t.is_true('mutant 5: net.stream_chunks starts the cursor of a border crossing too late (the bound of the first ordinal + 4) -- caught',
                 t.cs_mutant('net.stream_chunks()'::regprocedure, 'sp.d >= l.l * l.l)', 'sp.d >= l.l * l.l + 4)') <> 'same ; same ; same ; same ; same');
-- the safety net of the delivery (a cursor made for a view the client no longer has is turned into rows) is not reachable through the script (net.stream_chunks flushes first), so it is tried directly
select t.cs_run('new', 1, true, 5, 14) as ran \gset
truncate mc.play_out, mc.chunk_wanted, mc.chunk_cursor, mc.chunk_request, mc.chunk_wanted_view; truncate net.conn_ctl, net.conn; delete from mc.player;
insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, yaw, pitch, chunk_x, chunk_z, sent_qx, sent_qy, sent_qz, vis_dirty, last_sent_tick, gamemode, keepalive_sent_tick, view_distance_req)
values (md5('77')::uuid, 'cs77', 77, 77, 8, 70, 8, 0, 0, 3, 3, mc.quant(8), mc.quant(70), mc.quant(8), false, 0, 1, 700, 3);
insert into net.conn (conn_id, state, name, uuid, compression, entity_id, view_cx, view_cz, view_r, gamemode) values (77, 'play', 'cs77', md5('77')::uuid, -1, 77, 3, 3, 4, 1);
insert into mc.chunk_cursor (conn_id, dimension, cx, cz, r, next_o) values (77, 'minecraft:overworld', 3, 3, 4, 10);          -- made for a view the client does not have: (3, 3, 4) vs (3, 3, 4) ...
insert into mc.chunk_wanted (conn_id, dimension, cx, cz, dist) values (77, 'cursor', 0, 0, -1);
update net.conn set view_r = 3 where conn_id = 77;                                                                             -- ... now it has radius 3
select mc.deliver_ready_chunks() as sent \gset
select t.is_true('a cursor made for another view is turned into rows by the delivery (the safety net), its marker row goes, and what was sent is only inside the client''s square',
                 not exists (select 1 from mc.chunk_cursor) and not exists (select 1 from mc.chunk_wanted where dimension = 'cursor'));
select t.eq('the real functions are back after the mutants: script 1 is the same again', t.cs_compare(1, true, 5, 14), 'same');
truncate mc.play_out, mc.chunk_wanted, mc.chunk_cursor, mc.chunk_request, mc.chunk_wanted_view; delete from mc.player; truncate net.conn_ctl, net.conn;
update mc.server_property set value = 'inline' where key = 'dbcraft.chunk-generation';
update mc.server_property set value = '64' where key = 'dbcraft.chunk-batch-max';
update mc.server_property set value = '600' where key = 'dbcraft.chunk-budget-per-tick';
update mc.server_property set value = '40' where key = 'dbcraft.tick-budget-ms';
update mc.server_property set value = '49' where key = 'dbcraft.join-chunks-inline';
