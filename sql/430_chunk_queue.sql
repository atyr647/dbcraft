-- Chunk generation off the tick: the request queue, the wanted list, the generator loop, and the chunk hooks rewritten on top of them.
--
--   Setting dbcraft.chunk-generation (mc.server_property)
--     inline  (default)  a chunk a player needs is generated at once, inside the call that needs it (join, chunk streaming).  With the template generator
--                        (sql/245) that is cheap, and the behaviour is exactly the one the integration tests were written against.
--     async              the tick NEVER generates.  A chunk that does not exist yet is put on the request queue; a separate connection runs
--                        `call mc.run_generator()` (or mc.generate_pending in any loop you like) and the tick sends the chunk as soon as it exists.
--                        One player exploring cannot stall the tick for everybody.
--   Setting dbcraft.chunk-batch-max (async only): the most chunks one connection is sent per tick (a chunk_batch_start .. chunk_batch_finished group).
--
--   mc.chunk_request   what has to be generated, once per chunk however many players want it; prio = squared chunk distance of the nearest requester.
--                      Unlogged and transient.  Taken with FOR UPDATE SKIP LOCKED, so several generator loops can run in parallel without waiting for each other.
--   mc.chunk_wanted    what each connection has been promised and not yet been sent: (connection, chunk, distance).  Unlogged and transient.
--   mc.deliver_ready_chunks()   one tick step: for every connection, the wanted chunks that exist now, nearest first, as one chunk batch.
--
-- Everything stays rows: a chunk is ordinary chunk/section/light rows however it was produced, and the queue tables only say what to do next.

insert into mc.server_property (key, value, default_value, note) values
    ('dbcraft.chunk-generation', 'inline', 'inline', 'dbcraft: inline = generate missing chunks inside the call that needs them; async = queue them for mc.run_generator (the tick never generates)'),
    ('dbcraft.chunk-batch-max', '64', '64', 'dbcraft: async mode, most chunks sent to one connection per tick')
on conflict (key) do nothing;

create or replace function mc.chunk_generation_async() returns boolean language plpgsql stable as $$
begin return coalesce((select value from mc.server_property where key = 'dbcraft.chunk-generation') = 'async', false); end $$;

------------------------------------------------------------------------------------------------ tables
create unlogged table if not exists mc.chunk_request (
    dimension    text not null,
    cx           int  not null,
    cz           int  not null,
    prio         int  not null,                    -- squared distance of the nearest requester; smaller first
    pregen       boolean not null default false,   -- requested for its own sake (spawn area): generated even when nobody is waiting
    attempts     int  not null default 0,
    requested_at timestamptz not null default clock_timestamp(),
    primary key (dimension, cx, cz)
) with (fillfactor = 70);
create index if not exists chunk_request_order on mc.chunk_request (prio, requested_at);

create unlogged table if not exists mc.chunk_wanted (
    conn_id   int  not null,
    dimension text not null,
    cx        int  not null,
    cz        int  not null,
    dist      int  not null,
    primary key (conn_id, dimension, cx, cz)
) with (fillfactor = 70);
create index if not exists chunk_wanted_chunk on mc.chunk_wanted (dimension, cx, cz);

create table if not exists mc.generator_control (id int primary key default 1 check (id = 1), stop boolean not null default false);
insert into mc.generator_control (id) values (1) on conflict do nothing;

------------------------------------------------------------------------------------------------ generation
-- Generate up to p_max requested chunks (nearest requester first).  Returns how many chunks were created.  Safe to run from any number of connections at the
-- same time.  A request nobody waits for any more (every requester left or moved away) is dropped without generating, unless it was a pregeneration request.
create or replace function mc.generate_pending(p_max int default 64) returns int language plpgsql volatile as $$
declare
    g       record;
    made    int := 0;
    n       int;
begin
    -- nobody wants these any more (rows another generator holds are skipped, not waited for)
    delete from mc.chunk_request where ctid in (
        select r.ctid from mc.chunk_request r
         where not r.pregen and not exists (select 1 from mc.chunk_wanted w where w.dimension = r.dimension and w.cx = r.cx and w.cz = r.cz)
           for update skip locked);
    for g in
        with picked as (
            select r.dimension, r.cx, r.cz from mc.chunk_request r order by r.prio, r.requested_at limit p_max for update skip locked)
        select p.dimension, array_agg(p.cx) as cxs, array_agg(p.cz) as czs from picked p group by p.dimension
    loop
        begin
            n := mc.generate_batch(g.dimension, g.cxs, g.czs);
            made := made + n;
            -- docs/PERF-STORM.md: the packet of a new chunk is encoded here, on the generator's connection, not by the tick of the first player who is sent it (3-17 ms each, in a login storm
            -- 9 s of tick time over 7,000 chunks); a chunk that is edited later is re-encoded by the existing paths as before
            perform mc.chunk_packet(g.dimension, u.cx, u.cz) from unnest(g.cxs, g.czs) u(cx, cz);
            delete from mc.chunk_request r using unnest(g.cxs, g.czs) u(cx, cz) where r.dimension = g.dimension and r.cx = u.cx and r.cz = u.cz;
        exception when others then
            insert into mc.error_log (step, message) values ('generate_pending', g.dimension || ': ' || sqlerrm);
            update mc.chunk_request r set attempts = attempts + 1 from unnest(g.cxs, g.czs) u(cx, cz) where r.dimension = g.dimension and r.cx = u.cx and r.cz = u.cz;
            delete from mc.chunk_request where attempts >= 3;           -- a request that keeps failing must not block the queue
        end;
    end loop;
    return made;
end $$;

-- The generator loop: run it from its own connection (`call mc.run_generator();`), as many of them as you have cores to spare.  Commits after every batch.
-- Stops when mc.generator_control.stop is set, or after p_max_seconds.
-- Polling cost (sql/800, docs/PERF-IDLE.md): the poll is one EXISTS (the full request/delete statements only run when a request exists), and after p_idle_polls empty polls in a row the
-- sleep doubles with every further empty poll up to p_idle_max_ms, so an idle server's generators wake about 20 times a second instead of 200 (two connections used 0.07 of the 0.15
-- cores an empty server burnt).  A request waits at most p_idle_max_ms for a generator that has backed off; the first poll after work starts again at p_idle_ms.
drop procedure if exists mc.run_generator(int, int, int);
create or replace procedure mc.run_generator(p_batch int default 64, p_idle_ms int default 5, p_max_seconds int default null, p_idle_max_ms int default 50, p_idle_polls int default 20) language plpgsql as $$
declare n int; t0 timestamptz := clock_timestamp(); idle int := 0; sleep_ms float8;
begin
    loop
        n := 0;
        if exists (select 1 from mc.chunk_request) then n := mc.generate_pending(p_batch); end if;
        commit;
        exit when (select stop from mc.generator_control);
        exit when p_max_seconds is not null and clock_timestamp() - t0 > make_interval(secs => p_max_seconds);
        if n = 0 then
            idle := least(idle + 1, 1000);
            sleep_ms := case when idle <= p_idle_polls then p_idle_ms else least(p_idle_max_ms, p_idle_ms * power(2, least(idle - p_idle_polls, 20))) end;
            perform pg_sleep(sleep_ms / 1000.0);
        else
            idle := 0;
        end if;
        commit;
    end loop;
end $$;

-- Ask for (or just generate) a square of chunks around a point: spawn area, a region a script is about to edit, ...
create or replace function mc.pregenerate(p_dim text, p_cx int, p_cz int, p_r int, p_now boolean default true) returns int language plpgsql volatile as $$
declare n int;
begin
    if p_now then
        return mc.generate_batch(p_dim, array(select p_cx + dx from generate_series(-p_r, p_r) dx, generate_series(-p_r, p_r) dz order by dx, dz),
                                        array(select p_cz + dz from generate_series(-p_r, p_r) dx, generate_series(-p_r, p_r) dz order by dx, dz));
    end if;
    insert into mc.chunk_request (dimension, cx, cz, prio, pregen)
    select p_dim, p_cx + dx, p_cz + dz, dx * dx + dz * dz, true from generate_series(-p_r, p_r) dx, generate_series(-p_r, p_r) dz
     where not exists (select 1 from mc.chunk c where c.dimension = p_dim and c.cx = p_cx + dx and c.cz = p_cz + dz)
    on conflict (dimension, cx, cz) do update set prio = least(mc.chunk_request.prio, excluded.prio), pregen = true;
    get diagnostics n = row_count;
    return n;
end $$;

------------------------------------------------------------------------------------------------ wanting and delivering
-- A connection needs the chunks of a list (with distances).  Inline mode: the missing ones are generated now, in one batch.  Async mode: they go on the
-- request queue.  The list is recorded as wanted (mc.deliver_ready_chunks sends them) when p_record is true or in async mode; a caller that returns the chunks
-- itself in inline mode passes p_record = false so they are not sent twice.
create or replace function mc.want_chunks(p_conn int, p_dim text, p_cxs int[], p_czs int[], p_dists int[], p_record boolean default true) returns void language plpgsql volatile as $$
begin
    if p_record or mc.chunk_generation_async() then
        insert into mc.chunk_wanted (conn_id, dimension, cx, cz, dist)
        select p_conn, p_dim, u.cx, u.cz, u.d from unnest(p_cxs, p_czs, p_dists) u(cx, cz, d)
        on conflict (conn_id, dimension, cx, cz) do update set dist = excluded.dist;
    end if;
    if mc.chunk_generation_async() then
        insert into mc.chunk_request (dimension, cx, cz, prio)
        select p_dim, u.cx, u.cz, u.d from unnest(p_cxs, p_czs, p_dists) u(cx, cz, d)
         where not exists (select 1 from mc.chunk c where c.dimension = p_dim and c.cx = u.cx and c.cz = u.cz)
        on conflict (dimension, cx, cz) do update set prio = least(mc.chunk_request.prio, excluded.prio);
    else
        perform mc.generate_batch(p_dim, array_agg(u.cx), array_agg(u.cz))
           from unnest(p_cxs, p_czs) u(cx, cz)
          where not exists (select 1 from mc.chunk c where c.dimension = p_dim and c.cx = u.cx and c.cz = u.cz) having count(*) > 0;
    end if;
end $$;

-- The body of a framed chunk packet (what follows [length][id]); the id is below 128, so one byte.
create or replace function mc.packet_body(p bytea) returns bytea language sql immutable parallel safe as $$
  select substring(p from (case when get_byte(p, 0) < 128 then 1 when get_byte(p, 1) < 128 then 2 else 3 end) + 2) $$;

-- One tick step.  Drops what a connection no longer needs (gone, or moved out of range), then sends every connection the wanted chunks that exist now,
-- nearest first, as one chunk batch (at most dbcraft.chunk-batch-max per tick in async mode).  Frames go to mc.play_out like the rest of the tick's output.
create or replace function mc.deliver_ready_chunks() returns int language plpgsql volatile as $$
declare
    r     int := mc.prop_int('view-distance') + 1;
    cap   int := case when mc.chunk_generation_async() then coalesce(mc.prop_int('dbcraft.chunk-batch-max'), 64) else 2147483647 end;
    i_bs  int := mc.pid('chunk_batch_start');
    i_bf  int := mc.pid('chunk_batch_finished');
    n     int;
    rc int[]; rd text[]; rx int[]; rz int[]; rdist int[];       -- what is sent now: connection, dimension, chunk, distance (kept in arrays: see sql/437 on temp tables)
begin
    if not exists (select 1 from mc.chunk_wanted) then return 0; end if;
    delete from mc.chunk_wanted w
     where not exists (select 1 from net.conn c where c.conn_id = w.conn_id and c.state = 'play' and not c.closing and c.view_cx is not null
                          and abs(c.view_cx - w.cx) <= r and abs(c.view_cz - w.cz) <= r);
    select array_agg(q.conn_id), array_agg(q.dimension), array_agg(q.cx), array_agg(q.cz), array_agg(q.dist) into rc, rd, rx, rz, rdist
      from (select w.conn_id, w.dimension, w.cx, w.cz, w.dist, row_number() over (partition by w.conn_id order by w.dist, w.cx, w.cz) rn
              from mc.chunk_wanted w join mc.chunk c on c.dimension = w.dimension and c.cx = w.cx and c.cz = w.cz) q
     where q.rn <= cap;
    n := coalesce(cardinality(rc), 0);
    if n = 0 then return 0; end if;
    delete from mc.chunk_wanted w using unnest(rc, rd, rx, rz) as d(conn_id, dimension, cx, cz)
     where w.conn_id = d.conn_id and w.dimension = d.dimension and w.cx = d.cx and w.cz = d.cz;
    insert into mc.play_out (conn_id, data) select distinct d.conn_id, proto.frame(i_bs, '\x') from unnest(rc) as d(conn_id);
    insert into mc.play_out (conn_id, data) select d.conn_id, mc.chunk_packet(d.dimension, d.cx, d.cz) from unnest(rc, rd, rx, rz, rdist) as d(conn_id, dimension, cx, cz, dist) order by d.conn_id, d.dist, d.cx, d.cz;
    insert into mc.play_out (conn_id, data) select d.conn_id, proto.frame(i_bf, proto.varint(count(*)::int)) from unnest(rc) as d(conn_id) group by d.conn_id;
    return n;
end $$;

------------------------------------------------------------------------------------------------ the hooks, on top of the queue
-- net.hook_chunks (called when a player enters play): the chunks of the square that exist now, as bodies, nearest first.  The ones that do not exist are
-- generated at once (inline) or queued (async) and arrive through mc.deliver_ready_chunks.  Set-based: no per-chunk call.
-- sql/920 (docs/PERF-STORM.md): only the nearest dbcraft.join-chunks-inline chunks (default 49 = the whole square at view distance 2) are returned for the burst of the join;
-- the rest of the square is recorded as wanted and sent in the following ticks by mc.deliver_ready_chunks (nearest first, batches of at most dbcraft.chunk-batch-max,
-- like vanilla's chunk sender).  A square of 529 chunks at view distance 10 was 3.7 MB, about 80 ms of database time, inside ONE tick per joiner.  0 = everything inline (the old behaviour).
create or replace function net.hook_chunks(p_conn bigint, p_cx int, p_cz int, p_radius int) returns setof bytea language plpgsql volatile as $$
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

-- Chunk streaming for players that crossed a chunk border (tick step 6), plus delivery of everything that became ready.  Same packets, same order as
-- sql/410's version in inline mode (centre, forgets, then the batch); in async mode the new chunks are wanted and arrive as the generator produces them.
create or replace function net.stream_chunks() returns int language plpgsql as $$
declare r int := mc.prop_int('view-distance') + 1; dim text := 'minecraft:overworld'; n int;
        i_ctr int := mc.pid('set_chunk_cache_center'); i_fg int := mc.pid('forget_level_chunk');
begin
    if mc.world_ready() then
        create temp table if not exists _st (conn_id int primary key, ncx int, ncz int, ocx int, ocz int) on commit delete rows;
        delete from _st;
        insert into _st
        select c.conn_id, p.chunk_x, p.chunk_z, c.view_cx, c.view_cz
        from net.conn c join mc.player p on p.conn_id = c.conn_id
        where c.state = 'play' and not c.closing and c.view_cx is not null and (p.chunk_x, p.chunk_z) <> (c.view_cx, c.view_cz);
        get diagnostics n = row_count;
        if n > 0 then
            insert into mc.play_out (conn_id, data) select conn_id, proto.frame(i_ctr, proto.varint(ncx) || proto.varint(ncz)) from _st order by conn_id;
            -- chunks that left the client's square: z ascending, then x (the order of the one recorded case)
            insert into mc.play_out (conn_id, data)
            select s.conn_id, proto.frame(i_fg, proto.i32(s.ocz + dz) || proto.i32(s.ocx + dx))
            from _st s, generate_series(-r, r) dx, generate_series(-r, r) dz
            where abs(s.ocx + dx - s.ncx) > r or abs(s.ocz + dz - s.ncz) > r
            order by s.conn_id, s.ocz + dz, s.ocx + dx;
            -- the chunks that entered the square are wanted; the client's view moves now so they pass the range check of the delivery step
            update net.conn c set view_cx = s.ncx, view_cz = s.ncz from _st s where c.conn_id = s.conn_id;
            perform mc.want_chunks(s.conn_id, dim, array_agg(s.ncx + dx), array_agg(s.ncz + dz), array_agg(dx * dx + dz * dz))
               from _st s, generate_series(-r, r) dx, generate_series(-r, r) dz
              where abs(s.ncx + dx - s.ocx) > r or abs(s.ncz + dz - s.ocz) > r
              group by s.conn_id;
        end if;
    end if;
    perform mc.deliver_ready_chunks();
    return coalesce(n, 0);
end $$;
