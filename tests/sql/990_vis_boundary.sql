-- mc.refresh_visibility_vis (sql/909, docs/PERF-VIS2.md) tests only the pairs near the edge of the view circle; the neighbourhood version it replaced (mc.refresh_visibility_vis_nb, which tests every pair of a
-- dirty player; itself proven equal to the scan version in tests/sql/981) is the reference.  They must do EXACTLY the same on every tick of a long random walk: the same mc.visible, the same packets per
-- connection in the same order and the same player rows (the columns the refresh writes: not the three only the new function keeps).  The world is moved the way the server moves it: walkers (players become dirty when they
-- cross a chunk border or are 4 blocks from where their pairs were last evaluated, as mc.apply_player_moves has it), idle players, teleports whose client is still waiting for its chunks (stale viewers),
-- view distance changes, game mode changes (the trigger of sql/900 marks them for a re-check), leaves and joins (a new session of the same row), view distances 2 to 32, crowds and sparse layouts.
-- Every tick: the old function runs first in a sub-transaction that is rolled back (its digest is kept), then the new one runs for real and its digest is compared.  A mutation check at the end changes
-- the new function in the ways that would make it wrong (no slack, no stale rule, no range rule, no session rule) and shows that the comparison notices each of them.
update mc.server_property set value = 'true' where key = 'dbcraft.vanilla-tracker';
create temp table vb_stat (label text, ticks int, added bigint, removed bigint, packets bigint, dirty bigint);

-- the digest of what a refresh did: the pairs, the packets per connection in order, the columns of the player rows that the refresh writes or reads (not the three of the new function)
create or replace function t.vb_digest(out vis bigint[], out pk text[], out pl text) language plpgsql as $$
begin
  select coalesce(array_agg((viewer_eid::bigint << 24) | target_eid order by viewer_eid, target_eid), '{}') into vis from mc.visible;
  select coalesce(array_agg(x.c || ':' || md5(x.d) order by x.c), '{}') into pk
    from (select conn_id::text as c, string_agg(encode(data, 'hex'), ',' order by seq) as d from mc.play_out group by conn_id) x;
  select md5(coalesce(string_agg(row(p.conn_id, p.entity_id, p.x, p.z, p.chunk_x, p.chunk_z, p.gamemode, p.vis_dirty, p.vis_x, p.vis_z, p.vis_ocx, p.vis_ocz, p.tp_ground_tick, p.vis_recheck, p.view_distance_req)::text, '|' order by p.uuid), '')) into pl from mc.player p;
end $$;

create or replace function t.vb_case(p_label text, p_seed float8, p_n int, p_side int, p_vds int[], p_ticks int, p_speed float8, p_idle float8, p_spec float8, p_tp float8, p_vd float8, p_gm float8, p_jl float8,
                                     p_mut_from text default null, p_mut_to text default null, p_turn float8 default 0.05) returns text language plpgsql as $$
declare dn record; dold record; r_new record; r_old record; res text := 'same'; tk int; gt bigint; k int; nxt int := 100000; sz int := p_side * 16; orig text; mutated text;
        tot_add bigint := 0; tot_rem bigint := 0; tot_pk bigint := 0; tot_dirty bigint := 0; nd int; t0 timestamptz; ms_old float8 := 0; ms_new float8 := 0; ms_all timestamptz := clock_timestamp();
begin
  perform setseed(p_seed);
  if p_mut_from is not null then
    orig := pg_get_functiondef('mc.refresh_visibility_vis()'::regprocedure);
    mutated := replace(orig, p_mut_from, p_mut_to);
    if mutated = orig then raise exception 'the mutation % does not apply', p_mut_from; end if;
    execute mutated;
  end if;
  truncate mc.play_out, mc.visible, net.conn, mc.vtrk, mc.wp; delete from mc.player;
  update mc.game_state set game_time = 1000;
  update mc.server_property set value = '32' where key = 'view-distance';
  insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, yaw, pitch, chunk_x, chunk_z, sent_qx, sent_qy, sent_qz, vis_dirty, last_sent_tick, gamemode, keepalive_sent_tick, view_distance_req)
  select md5(i::text)::uuid, 'v' || i, i, i, px, 70, pz, random() * 360, 0, floor(px / 16)::int, floor(pz / 16)::int, mc.quant(px), mc.quant(70), mc.quant(pz), true, 0,
         case when random() < p_spec then 3 else 1 end, 0, p_vds[1 + (random() * (cardinality(p_vds) - 1))::int]
    from (select i, random() * sz as px, random() * sz as pz from generate_series(1, p_n) i) g;
  insert into net.conn (conn_id, state, name, uuid, compression, entity_id, view_cx, view_cz, gamemode)
  select conn_id, 'play', name, uuid, -1, entity_id, chunk_x, chunk_z, gamemode from mc.player;
  for tk in 1..p_ticks loop
    gt := 1000 + tk;
    update mc.game_state set game_time = gt;
    if tk > 1 then
      -- walkers: along the heading, turning round at the edge of the arena, sometimes a new heading; idle players stay
      update mc.player p set x = n.nx, z = n.nz, chunk_x = floor(n.nx / 16)::int, chunk_z = floor(n.nz / 16)::int, yaw = n.nyaw, last_move_tick = gt,
             vis_dirty = p.vis_dirty or floor(n.nx / 16)::int <> p.chunk_x or floor(n.nz / 16)::int <> p.chunk_z or (n.nx - p.vis_x) ^ 2 + (n.nz - p.vis_z) ^ 2 >= 16,
             vis_ocx = case when not p.vis_dirty and (floor(n.nx / 16)::int <> p.chunk_x or floor(n.nz / 16)::int <> p.chunk_z or (n.nx - p.vis_x) ^ 2 + (n.nz - p.vis_z) ^ 2 >= 16) then p.chunk_x else p.vis_ocx end,
             vis_ocz = case when not p.vis_dirty and (floor(n.nx / 16)::int <> p.chunk_x or floor(n.nz / 16)::int <> p.chunk_z or (n.nx - p.vis_x) ^ 2 + (n.nz - p.vis_z) ^ 2 >= 16) then p.chunk_z else p.vis_ocz end
        from (select q.entity_id, case when q.out then q.yaw + 180 + (random() - .5) * 40 when random() < p_turn then random() * 360 else q.yaw end as nyaw,
                     case when q.out then q.x else q.px end as nx, case when q.out then q.z else q.pz end as nz
                from (select e.entity_id, e.yaw, e.x, e.z, e.px, e.pz, (e.px < 2 or e.px > sz - 2 or e.pz < 2 or e.pz > sz - 2) as out
                        from (select m.entity_id, m.yaw, m.x, m.z, m.x - sin(radians(m.yaw)) * s as px, m.z + cos(radians(m.yaw)) * s as pz
                                from (select p2.entity_id, p2.yaw, p2.x, p2.z, p_speed * random() * 2 as s from mc.player p2 where p2.conn_id is not null and random() >= p_idle) m) e) q) n
       where p.entity_id = n.entity_id;
      -- teleports (the client keeps its old view until the chunks of the new place were sent)
      update mc.player set x = x + (random() - .5) * 24, z = z + (random() - .5) * 24, vis_dirty = true, vis_ocx = null, vis_ocz = null, tp_ground_tick = gt + 2, last_move_tick = gt
       where conn_id is not null and random() < p_tp / 2;                    -- (half of the teleports a few blocks, which the bound has to notice too)
      update mc.player set x = random() * sz, z = random() * sz, vis_dirty = true, vis_ocx = null, vis_ocz = null, tp_ground_tick = gt + 2, last_move_tick = gt where conn_id is not null and random() < p_tp / 2;
      update mc.player set chunk_x = floor(x / 16)::int, chunk_z = floor(z / 16)::int where conn_id is not null and tp_ground_tick = gt + 2;
      -- view distance changes and game mode changes
      update mc.player set view_distance_req = p_vds[1 + (random() * (cardinality(p_vds) - 1))::int], vis_dirty = true, vis_ocx = null, vis_ocz = null where conn_id is not null and random() < p_vd;
      update mc.player set gamemode = case when gamemode = 3 then 1 else 3 end where conn_id is not null and random() < p_gm;
      -- leaves and joins: a leaver loses its pairs and its row stays; a joiner is a new session (new entity id) of an offline row, somewhere else
      for k in select entity_id from mc.player where conn_id is not null and random() < p_jl loop
        delete from mc.visible where viewer_eid = k or target_eid = k;
        delete from net.conn where entity_id = k;
        update mc.player set conn_id = null, entity_id = null, vis_dirty = false, tp_ground_tick = null where entity_id = k;
      end loop;
      for k in select 1 from mc.player where conn_id is null and random() < 0.5 loop
        nxt := nxt + 1;
        update mc.player set conn_id = nxt, entity_id = nxt, x = random() * sz, z = random() * sz, vis_dirty = true, vis_ocx = null, vis_ocz = null, tp_ground_tick = null, last_move_tick = gt
         where uuid = (select uuid from mc.player where conn_id is null order by random() limit 1);
        update mc.player set chunk_x = floor(x / 16)::int, chunk_z = floor(z / 16)::int where entity_id = nxt;
        insert into net.conn (conn_id, state, name, uuid, compression, entity_id, view_cx, view_cz, gamemode) select conn_id, 'play', name, uuid, -1, entity_id, chunk_x, chunk_z, gamemode from mc.player where entity_id = nxt;
      end loop;
      -- the clients get their chunks: a teleported one after a while, the others at once
      update net.conn c set view_cx = p.chunk_x, view_cz = p.chunk_z from mc.player p where p.conn_id = c.conn_id and (p.tp_ground_tick is null or random() < 0.5);
      update mc.player set tp_ground_tick = null where tp_ground_tick is not null and gt >= tp_ground_tick and random() < 0.7;
    end if;
    select count(*) into nd from mc.player where vis_dirty and conn_id is not null;
    tot_dirty := tot_dirty + nd;
    -- the reference, rolled back
    begin
      t0 := clock_timestamp();
      select * into r_old from mc.refresh_visibility_vis_nb();
      ms_old := ms_old + extract(epoch from clock_timestamp() - t0) * 1000;
      select * into dold from t.vb_digest();
      raise exception 'rollback' using errcode = 'VB001';
    exception when sqlstate 'VB001' then null;
    end;
    t0 := clock_timestamp();
    select * into r_new from mc.refresh_visibility_vis();
    ms_new := ms_new + extract(epoch from clock_timestamp() - t0) * 1000;
    select * into dn from t.vb_digest();
    tot_add := tot_add + r_new.added; tot_rem := tot_rem + r_new.removed; tot_pk := tot_pk + cardinality(dn.pk);
    if r_new.added <> r_old.added or r_new.removed <> r_old.removed then
      res := format('tick %s: counts (%s,%s) vs reference (%s,%s)', tk, r_new.added, r_new.removed, r_old.added, r_old.removed); exit;
    end if;
    if dn.vis <> dold.vis then
      res := format('tick %s: mc.visible differs: %s pairs only in the new, %s only in the reference', tk, (select count(*) from (select unnest(dn.vis) except select unnest(dold.vis)) x), (select count(*) from (select unnest(dold.vis) except select unnest(dn.vis)) x)); exit;
    end if;
    if dn.pk <> dold.pk then res := format('tick %s: the packets differ on %s connections', tk, (select count(*) from (select unnest(dn.pk) except select unnest(dold.pk)) x)); exit; end if;
    if dn.pl <> dold.pl then res := format('tick %s: the player rows differ', tk); exit; end if;
    truncate mc.play_out;
  end loop;
  if p_mut_from is not null then execute orig; end if;
  raise notice '     % : % ticks, % dirty players, reference % ms, new % ms, case % ms', p_label, p_ticks, tot_dirty, round(ms_old), round(ms_new), round(extract(epoch from clock_timestamp() - ms_all) * 1000);
  insert into vb_stat values (p_label, p_ticks, tot_add, tot_rem, tot_pk, tot_dirty);
  return res;
end $$;

-- long walks with more than 200 players: a crowd that sees itself, mixed view distances 2 to 32 with everything happening at once, and a world so sparse that nobody sees anybody but a few
select t.eq('crowd: 210 players over 10 x 10 chunks, view distances 3-10, walkers (100 ticks)', t.vb_case('crowd', 0.32, 210, 10, array[3, 4, 6, 8, 10], 100, 0.4, 0.1, 0.05, 0.0, 0.0, 0.0, 0.0), 'same');
select t.eq('everything at once: 220 players over 24 x 24 chunks, view distances 2-32, teleports, view and game mode changes, leaves and joins (110 ticks)',
            t.vb_case('all', 0.39, 220, 24, array[2, 3, 4, 8, 12, 20, 32], 110, 0.8, 0.1, 0.1, 0.01, 0.02, 0.02, 0.01), 'same');
select t.eq('very sparse: 200 players over 100 x 100 chunks, view 10 (100 ticks)', t.vb_case('sparse100', 0.34, 200, 100, array[10], 100, 1.1, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0), 'same');
-- one thing at a time
select t.eq('teleports whose clients wait for their chunks, spectators', t.vb_case('tp', 0.35, 120, 14, array[2, 4, 8, 10], 60, 0.5, 0.1, 0.15, 0.03, 0.0, 0.0, 0.0), 'same');
select t.eq('fast movers (jumps of several blocks a tick, beyond the 4 block bound)', t.vb_case('fast', 0.36, 120, 12, array[3, 6, 10], 60, 5.0, 0.0, 0.05, 0.0, 0.0, 0.0, 0.0), 'same');
select t.eq('view distance changes and game mode changes while walking', t.vb_case('vd/gm', 0.37, 120, 14, array[2, 3, 5, 8, 12, 32], 60, 0.7, 0.1, 0.1, 0.0, 0.04, 0.04, 0.0), 'same');
select t.eq('leaves and joins (new sessions of the same rows)', t.vb_case('join', 0.38, 120, 14, array[2, 4, 8, 10], 60, 0.7, 0.1, 0.05, 0.0, 0.0, 0.0, 0.03), 'same');
select t.eq('8 more random worlds', (select count(*) filter (where t.vb_case('rnd' || s, 0.6 + s / 100.0, 40 + s * 10, 3 + s * 3, array[2, 3, 5, 7, 10, 14, 32], 30, 0.2 + (s % 6) * 0.35, (s % 3) * 0.1, (s % 4) * 0.1, (s % 3) * 0.01, (s % 2) * 0.02, (s % 4) * 0.01, (s % 5) * 0.005) <> 'same') from generate_series(1, 8) s)::int, 0);
select t.is_true('the walks exercised adding and removing pairs and packets (' || (select sum(added) from vb_stat) || ' added, ' || (select sum(removed) from vb_stat) || ' removed, ' || (select sum(packets) from vb_stat) || ' packets, '
                 || (select sum(dirty) from vb_stat) || ' dirty players evaluated in ' || (select sum(ticks) from vb_stat) || ' ticks)',
                 (select sum(added) > 10000 and sum(removed) > 10000 and sum(packets) > 3000 and sum(ticks) >= 700 from vb_stat));

-- the mutation check: each of these changes makes the new function wrong in one way; the comparison must notice it (a test that cannot fail proves nothing)
select t.is_true('mutation: no slack for the player that was not evaluated (2.005 -> 0.05), jittering walkers', t.vb_case('mut1', 0.41, 150, 8, array[10], 60, 1.2, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, '+ 2.005 else', '+ 0.05 else', 0.7) <> 'same');
select t.is_true('mutation: a client that waited for its chunks keeps a trusted evaluation', t.vb_case('mut2', 0.42, 120, 10, array[3, 6, 10], 60, 0.6, 0.0, 0.0, 0.06, 0.0, 0.0, 0.0, 'update mc.player p set vis_eid = null where p.entity_id = any (sv) and p.vis_eid is not null;', 'null;') <> 'same');
select t.is_true('mutation: a changed view distance is not noticed', t.vb_case('mut3', 0.43, 120, 10, array[3, 6, 10, 16], 60, 0.6, 0.0, 0.0, 0.0, 0.08, 0.0, 0.0, 'p.vis_rng is not distinct from l.rng and ', '') <> 'same');
select t.is_true('mutation: a new session of a row is trusted (the session rule)', t.vb_case('mut4', 0.44, 120, 10, array[3, 6, 10], 60, 0.6, 0.0, 0.0, 0.0, 0.0, 0.0, 0.05, 'p.vis_eid is not distinct from p.entity_id and ', '') <> 'same');
select t.is_true('mutation: a changed game mode is not noticed', t.vb_case('mut5', 0.45, 120, 10, array[3, 6, 10], 60, 0.6, 0.0, 0.3, 0.0, 0.0, 0.08, 0.0, 'p.vis_spec is not distinct from (p.gamemode = 3) and ', '') <> 'same');
select t.is_true('mutation: the bound ignores how far the players have moved (k is a constant)', t.vb_case('mut6', 0.46, 120, 10, array[3, 6, 10], 60, 0.9, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 'then sqrt((p.x - p.vis_x) ^ 2', 'then 0.0 * sqrt((p.x - p.vis_x) ^ 2') <> 'same');
-- the original is back after the mutations
select t.eq('the function is back to its definition', t.vb_case('after', 0.47, 100, 10, array[3, 6, 10], 30, 0.9, 0.0, 0.05, 0.02, 0.02, 0.02, 0.01), 'same');
