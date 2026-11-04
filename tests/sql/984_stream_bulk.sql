-- net.stream_chunks in async mode records what the players that crossed a chunk border want with two set-based statements (sql/436, docs/PERF-CAPACITY.md); the version before did it with one
-- mc.want_chunks call per connection.  t.stream_chunks_old below is that version, pasted; both must leave the same mc.chunk_wanted, mc.chunk_request (with the smallest distance of
-- the requesters), mc.play_out per connection, net.conn views.  Random crossings (one chunk, a diagonal, a jump), per-client view distances (the vanilla tracker), a backlog of wanted rows
-- that stays, chunks that exist and chunks that do not, two players asking for the same missing chunk at different distances.
create or replace function t.stream_chunks_old() returns int language plpgsql as $$
declare srv int := mc.prop_int('view-distance'); vison boolean := mc.vis_on(); dim text := 'minecraft:overworld'; n int;
        i_ctr int := mc.pid('set_chunk_cache_center'); i_fg int := mc.pid('forget_level_chunk');
        sc int[]; sncx int[]; sncz int[]; socx int[]; socz int[]; snr int[]; sor int[];
begin
    if mc.world_ready() then
        select array_agg(c.conn_id::int), array_agg(p.chunk_x), array_agg(p.chunk_z), array_agg(c.view_cx), array_agg(c.view_cz),
               array_agg(case when vison then greatest(2, least(coalesce(p.view_distance_req, 2), srv)) + 1 else srv + 1 end), array_agg(coalesce(c.view_r, srv + 1))
          into sc, sncx, sncz, socx, socz, snr, sor
        from net.conn c join mc.player p on p.conn_id = c.conn_id
        where c.state = 'play' and not c.closing and c.view_cx is not null
          and ((p.chunk_x, p.chunk_z) <> (c.view_cx, c.view_cz) or coalesce(c.view_r, srv + 1) <> (case when vison then greatest(2, least(coalesce(p.view_distance_req, 2), srv)) + 1 else srv + 1 end));
        n := coalesce(cardinality(sc), 0);
        if n > 0 then
            insert into mc.play_out (conn_id, data)
            select s.conn_id, proto.frame(i_ctr, proto.varint(s.ncx) || proto.varint(s.ncz)) from unnest(sc, sncx, sncz, socx, socz) as s(conn_id, ncx, ncz, ocx, ocz) where (s.ncx, s.ncz) <> (s.ocx, s.ocz) order by s.conn_id;
            insert into mc.play_out (conn_id, data)
            select s.conn_id, proto.frame(i_fg, proto.i32(s.ocz + dz) || proto.i32(s.ocx + dx))
            from unnest(sc, sncx, sncz, socx, socz, snr, sor) as s(conn_id, ncx, ncz, ocx, ocz, nr, orr), generate_series(-s.orr, s.orr) dx, generate_series(-s.orr, s.orr) dz
            where abs(s.ocx + dx - s.ncx) > s.nr or abs(s.ocz + dz - s.ncz) > s.nr
            order by s.conn_id, s.ocx + dx, s.ocz + dz;
            update net.conn c set view_cx = s.ncx, view_cz = s.ncz, view_r = s.nr from unnest(sc, sncx, sncz, snr) as s(conn_id, ncx, ncz, nr) where c.conn_id = s.conn_id;
            perform mc.want_chunks(q.conn_id, dim, array_agg(q.x), array_agg(q.z), array_agg(q.d))
              from (select s.conn_id, s.ncx + dx as x, s.ncz + dz as z, dx * dx + dz * dz as d
                      from unnest(sc, sncx, sncz, socx, socz, snr, sor) as s(conn_id, ncx, ncz, ocx, ocz, nr, orr), generate_series(-s.nr, s.nr) dx, generate_series(-s.nr, s.nr) dz
                     where abs(s.ncx + dx - s.ocx) > s.orr or abs(s.ncz + dz - s.ocz) > s.orr) q
             group by q.conn_id;
        end if;
    end if;
    perform mc.deliver_ready_chunks();
    return coalesce(n, 0);
end $$;

create or replace function t.sc_build(p_seed float8, p_n int, p_view int) returns void language plpgsql as $$
begin
  perform setseed(p_seed);
  truncate net.conn_ctl, net.conn, net.inbox, net.outbox, mc.play_out, mc.chunk_wanted, mc.chunk_request, mc.chunk_wanted_view, mc.visible, mc.vtrk, mc.wp;
  delete from mc.player;
  update mc.server_property set value = p_view::text where key = 'view-distance';
  update mc.server_property set value = 'async' where key = 'dbcraft.chunk-generation';
  update mc.server_property set value = '600' where key = 'dbcraft.chunk-budget-per-tick';
  update mc.game_state set game_time = 700;
  -- a patch of existing chunks, the rest of the world is missing
  truncate mc.chunk cascade;
  perform mc.generate_batch('minecraft:overworld', array_agg(x), array_agg(z)) from generate_series(-4, 12) x, generate_series(-4, 12) z where random() < .6;
  insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, yaw, pitch, chunk_x, chunk_z, sent_qx, sent_qy, sent_qz, vis_dirty, last_sent_tick, gamemode, keepalive_sent_tick, view_distance_req)
  select md5(g::text)::uuid, 'sc' || g, g, g, 8, 70, 8, 0, 0, (random() * 6)::int, (random() * 6)::int, mc.quant(8), mc.quant(70), mc.quant(8), false, 0, 1, 700, (array[null, 2, 3, 4, 6, 8, 10])[1 + (random() * 6)::int]
    from generate_series(1, p_n) g;
  insert into net.conn (conn_id, state, name, uuid, compression, entity_id, view_cx, view_cz, view_r, gamemode)
  select conn_id, 'play', name, uuid, -1, entity_id, chunk_x, chunk_z, case when random() < .7 then greatest(2, least(coalesce(view_distance_req, 2), p_view)) + 1 end, gamemode from mc.player;
  -- crossings: one chunk, a diagonal, a jump of 20 chunks (the new square does not touch the old), nobody
  update mc.player set chunk_x = chunk_x + case when random() < .3 then 1 when random() < .3 then -1 else 0 end, chunk_z = chunk_z + case when random() < .3 then 1 else 0 end where random() < .7;
  update mc.player set chunk_x = chunk_x + 20 where conn_id % 7 = 3;
  -- a backlog that stays (chunks some connections were promised earlier that are not generated yet or outside the new square)
  insert into mc.chunk_wanted (conn_id, dimension, cx, cz, dist) select conn_id, 'minecraft:overworld', chunk_x + 2, chunk_z - 3, 13 from mc.player where conn_id % 3 = 0 on conflict do nothing;
  insert into mc.chunk_wanted (conn_id, dimension, cx, cz, dist) select conn_id, 'minecraft:overworld', 100 + conn_id, 100, 99 from mc.player where conn_id % 4 = 0 on conflict do nothing;
end $$;

create or replace function t.sc_digest() returns text language sql as $$
  select md5(coalesce((select string_agg(conn_id || ':' || cx || ',' || cz || ':' || dist, ' ' order by conn_id, cx, cz) from mc.chunk_wanted), '') || '|'
          || coalesce((select string_agg(cx || ',' || cz || ':' || prio, ' ' order by cx, cz) from mc.chunk_request), '') || '|'
          || coalesce((select string_agg(conn_id || ':' || encode(d, 'hex'), ' ' order by conn_id) from (select conn_id, string_agg(data, ''::bytea order by seq) d from mc.play_out group by conn_id) q), '') || '|'
          || coalesce((select string_agg(conn_id || ':' || view_cx || ',' || view_cz || ',' || coalesce(view_r, -1), ' ' order by conn_id) from net.conn), '')) $$;

create or replace function t.sc_run(p_old boolean, p_seed float8, p_n int, p_view int) returns text language plpgsql as $$
begin
  perform t.sc_build(p_seed, p_n, p_view);
  if p_old then perform t.stream_chunks_old(); else perform net.stream_chunks(); end if;
  return t.sc_digest();
end $$;

select t.sc_run(false, 0.31, 14, 5) is not null as ran;
select t.is_true('the scenario is not empty: chunks are wanted, requested and delivered', (select count(*) from mc.chunk_request) > 20 and (select count(*) from mc.play_out) > 100);
select t.eq('view distance 5, 14 players: the bulk statements == the per-connection calls', t.sc_run(false, 0.31, 14, 5), t.sc_run(true, 0.31, 14, 5));
select t.eq('view distance 2, 20 players', t.sc_run(false, 0.32, 20, 2), t.sc_run(true, 0.32, 20, 2));
select t.eq('view distance 8, 6 players', t.sc_run(false, 0.33, 6, 8), t.sc_run(true, 0.33, 6, 8));
select t.eq('view distance 10, 30 players', t.sc_run(false, 0.34, 30, 10), t.sc_run(true, 0.34, 30, 10));
select t.eq('6 more random scenarios', (select count(*) filter (where t.sc_run(false, 0.4 + s::float8 / 100, 5 + s * 3, 2 + s) <> t.sc_run(true, 0.4 + s::float8 / 100, 5 + s * 3, 2 + s)) from generate_series(1, 6) s)::int, 0);
update mc.server_property set value = 'inline' where key = 'dbcraft.chunk-generation';
