-- Pairing deferral for login storms (sql/903 mc.vis_pair_release, docs/PERF-PAIRING.md).  A joiner is queued in mc.vpair by mc.vis_join and paired with its viewers (entity bundles in both
-- directions, the first tracker pass, the locator bar's connections of the new source) when the pairing budget lets it out of the queue.  What has to hold:
--   1. with the queue never over budget (or the budget off) everything is where it always was: the same mc.visible, mc.wp and the same bytes per connection IN THE SAME ORDER on every tick;
--   2. over budget a joiner waits (and neither sees nor is seen: no pair, no waypoint connection, no frame of it for anybody else), the queue leaves in the order of joining, at least dbcraft.pair-free
--      per tick, nobody waits longer than dbcraft.pair-max-wait-ticks;
--   3. when the queue is empty again the world is what the undeferred run made of it: the same mc.visible, the same mc.wp, and for every connection the same frames (the bytes of every pairing
--      bundle and of every locator packet are the same, only the tick they were sent in differs: compared as the sorted list of frames of the whole run).  Returning players only: a first-time
--      player's attribute map is empty for three ticks, so a pair formed after that carries the attributes in the bundle instead of in a later update_attributes (the same state, other frames);
--   4. mutations of the deferral are noticed by this test (the queue ignored by the pair search, by the locator pass).
select (select count(*) from ref.registry where registry = 'minecraft:attribute') > 0 and (select count(*) from net.static_packet) >= 6 as have_data \gset
\if :have_data
update mc.server_property set value = 'false' where key = 'white-list'; update mc.server_property set value = 'survival' where key = 'gamemode';
update mc.server_property set value = 'normal' where key = 'difficulty'; update mc.server_property set value = '10' where key in ('view-distance', 'simulation-distance');
update mc.server_property set value = 'true' where key = 'dbcraft.vanilla-tracker';
select mc.configure_dev_server('t', 'survival');
update mc.server_property set value = '10' where key in ('view-distance', 'simulation-distance'); select net.sync_settings();
delete from mc.game_rule; truncate mc.tick_log;

create temp table pd_res (label text, vis text, wp text, frames text, per_tick text, max_wait int, qlen int[], leaked int);

create or replace function t.pd_frames(d bytea) returns text[] language plpgsql as $$
declare o int := 0; l record; r text[] := '{}';
begin
  while o < length(d) loop
    select * into l from proto.varint_read(d, o);
    r := r || encode(substring(d from o + 1 for l.nxt - o + l.val), 'hex');
    o := l.nxt + l.val;
  end loop;
  return r;
end $$;

-- one run: p_n returning players are online and settled; then joiners come p_per at a time, one batch per tick, over p_jt ticks, and the world ticks p_ticks in all.
--   p_budget: the setting dbcraft.pair-budget-ms of the run ('off' = the old behaviour); p_ema: the moving average of the cost of a pairing the run starts with (what makes the budget bite)
create or replace function t.pd_run(p_label text, p_seed float8, p_n int, p_joiners int, p_per int, p_ticks int, p_budget text, p_ema float8, p_mut text default null) returns void language plpgsql as $$
declare i int; tk int; gt bigint; side float8 := 300; conn int; pos record; eid int; ql int[] := '{}'; wmax int := 0; leaked int := 0; digest text[] := '{}'; nq int; orig text; mutated text; q record;
        frames text[]; sig text;
begin
  perform setseed(p_seed / 100.0);
  if p_mut is not null then
    -- the three places that leave a queued joiner out: the dirty / first / transmit-state test of mc.vis_find, the partner list of the pair search, the transmit state of the locator pass
    sig := case p_mut when 'vis_find' then 'mc.vis_find(bigint)' when 'refresh' then 'mc.refresh_visibility_vis()' else 'mc.vis_wp_pass(bigint,int,int)' end;
    orig := pg_get_functiondef(sig::regprocedure);
    mutated := case p_mut when 'vis_find' then replace(orig, 'and not q.pn', 'and not false')
                          when 'refresh' then replace(replace(orig, 'and not (p.entity_id = any (coalesce(pend, ''{}'')))', ''), 'and not (entity_id = any (coalesce(pend, ''{}'')))', '')
                          else replace(orig, 'p_phase = 2 and not (p.entity_id = any (pend))', 'p_phase = 2') end;
    if mutated = orig then raise exception 'the mutation % does not apply', p_mut; end if;
    execute mutated;
  end if;
  truncate mc.play_out, mc.visible, net.conn, mc.vtrk, mc.wp, mc.vpair; delete from mc.player; perform setval('mc.entity_id_seq', 1, false);
  update mc.game_state set game_time = 1000;
  update mc.server_property set value = 'off' where key = 'dbcraft.pair-budget-ms';
  update mc.server_property set value = '1' where key = 'dbcraft.pair-free';
  update mc.server_property set value = '8' where key = 'dbcraft.pair-max-wait-ticks';
  for i in 1 .. p_n + p_joiners loop
    insert into mc.player (uuid, name, first_seen, x, z, chunk_x, chunk_z) select md5('pd' || i)::uuid, 'pd' || i, now() - interval '1 day', g.px, g.pz, floor(g.px / 16)::int, floor(g.pz / 16)::int from (select random() * side as px, random() * side as pz) g;       -- (a returning player: its row exists with its place; on_join keeps it)
  end loop;
  -- the settled population: joined with the budget off, a few ticks to settle
  for i in 1 .. p_n loop
    conn := i;
    update mc.game_state set spawn_x = random() * side, spawn_z = random() * side;
    insert into net.conn (conn_id, state, name, uuid, compression, client_info) values (conn, 'play', 'pd' || i, md5('pd' || i)::uuid, -1, '{"view_distance": 10, "skin_parts": 0, "main_hand": 1}'::jsonb);
    perform mc.on_join(conn, md5('pd' || i)::uuid, 'pd' || i, false);
    perform mc.vis_join(conn, md5('pd' || i)::uuid);
  end loop;
  for tk in 1 .. 12 loop
    gt := 1000 + tk; update mc.game_state set game_time = gt;
    perform mc.refresh_visibility(); perform mc.vis_step(gt);
  end loop;
  truncate mc.play_out;
  update mc.server_property set value = p_budget where key = 'dbcraft.pair-budget-ms';
  update mc.vpair_state set ema_ms = p_ema, released = 0, deferred_ticks = 0, max_depth = 0;
  for tk in 13 .. 12 + p_ticks loop
    gt := 1000 + tk; update mc.game_state set game_time = gt;
    -- the network phase: this tick's joiners
    if tk - 12 <= (p_joiners + p_per - 1) / p_per then
      for i in 1 .. least(p_per, p_joiners - (tk - 13) * p_per) loop
        conn := p_n + (tk - 13) * p_per + i;
        update mc.game_state set spawn_x = random() * side, spawn_z = random() * side;
        insert into net.conn (conn_id, state, name, uuid, compression, client_info) values (conn, 'play', 'pd' || conn, md5('pd' || conn)::uuid, -1, '{"view_distance": 10, "skin_parts": 0, "main_hand": 1}'::jsonb);
        perform mc.on_join(conn, md5('pd' || conn)::uuid, 'pd' || conn, false);
        perform mc.vis_join(conn, md5('pd' || conn)::uuid);
      end loop;
    end if;
    perform mc.refresh_visibility(); perform mc.vis_step(gt);
    select count(*)::int into nq from mc.vpair;
    ql := ql || nq;
    -- a queued joiner is nobody's pair and nobody's waypoint source; nothing in this tick's output names its connection as a target either (frames to others carry its entity id / uuid)
    for q in select p.conn_id, p.entity_id, p.uuid from mc.player p join mc.vpair v on v.entity_id = p.entity_id loop
      leaked := leaked + (select count(*) from mc.visible where viewer_eid = q.entity_id or target_eid = q.entity_id)::int
                       + (select count(*) from mc.wp where src = q.entity_id)::int;
    end loop;
    digest := digest || (select coalesce(string_agg(x.c || ':' || md5(x.d), ',' order by x.c), '') from (select conn_id::text as c, string_agg(encode(data, 'hex'), ',' order by seq) as d from mc.play_out group by conn_id) x);
    select coalesce(array_agg(f order by f), '{}') into frames from (select unnest(t.pd_frames(data)) f from mc.play_out) z;       -- (kept below, appended to the run's list)
    insert into pd_res (label, frames) values (p_label || '#f', array_to_string(frames, '|'));
    truncate mc.play_out;
  end loop;
  insert into pd_res (label, vis, wp, per_tick, qlen, leaked, max_wait)
  select p_label,
         (select md5(coalesce(string_agg(viewer_eid || '>' || target_eid, ',' order by viewer_eid, target_eid), '')) from mc.visible),
         (select md5(coalesce(string_agg(rcv || '>' || src || ':' || kind, ',' order by rcv, src), '')) from mc.wp),
         md5(array_to_string(digest, '/')), ql, leaked, (select deferred_ticks::int from mc.vpair_state);
  if p_mut is not null then execute orig; end if;
end $$;

-- the frames of two runs compared: every frame that is not a first-tracker-pass duplicate must occur exactly as often in both; the first pass of a joiner repeats the entity data and the attributes
-- of its pairing bundle to the viewers it has at that moment (sql/907), so a joiner paired a tick later than another one does not get the repeat of that one's first pass (it is vanilla's too: a pair
-- formed later carries the current state once), and so does the zero move of the tracker's first body (tickCount 0, a position refresh): for those packets "no more often than in the undeferred run" (and, for the entity data and the attributes, "at all") is required.
create or replace function t.pd_cmp(p_a text, p_b text) returns text language plpgsql as $$
declare dup1 int; dup2 int; dup3 int; r record; msg text := 'same';
begin
  select protocol_id into dup1 from ref.packet where state = 'play' and direction = 'clientbound' and name = 'minecraft:set_entity_data';
  select protocol_id into dup2 from ref.packet where state = 'play' and direction = 'clientbound' and name = 'minecraft:update_attributes';
  select protocol_id into dup3 from ref.packet where state = 'play' and direction = 'clientbound' and name = 'minecraft:move_entity_pos';
  for r in
    with a as (select f, count(*) n from (select unnest(string_to_array(frames, '|')) f from pd_res where label = p_a || '#f' and frames <> '') z group by f),
         b as (select f, count(*) n from (select unnest(string_to_array(frames, '|')) f from pd_res where label = p_b || '#f' and frames <> '') z group by f),
         j as (select coalesce(a.f, b.f) f, coalesce(a.n, 0) na, coalesce(b.n, 0) nb from a full join b on a.f = b.f)
    select j.*, (proto.varint_read(decode(j.f, 'hex'), (proto.varint_read(decode(j.f, 'hex'), 0)).nxt)).val as pid from j where j.na <> j.nb
  loop
    if r.pid in (dup1, dup2) and r.na <= r.nb and (r.na > 0) = (r.nb > 0) then continue; end if;
    if r.pid = dup3 and r.na <= r.nb then continue; end if;       -- (the zero move of the first body: a pair formed after it does not get it at all)
    msg := 'differs: ' || left(r.f, 40) || ' ' || r.na || ' against ' || r.nb; exit;
  end loop;
  return msg;
end $$;

------------------------------------------------------------------------------------------------ 1. below the budget nothing moves
select t.pd_run('ref1', 11, 30, 6, 2, 12, 'off', 2.0);
select t.pd_run('bud1', 11, 30, 6, 2, 12, '1000', 2.0);
select t.eq('budget big enough: the same mc.visible as the old behaviour', (select vis from pd_res where label = 'bud1'), (select vis from pd_res where label = 'ref1'));
select t.eq('   the same locator connections', (select wp from pd_res where label = 'bud1'), (select wp from pd_res where label = 'ref1'));
select t.eq('   the same bytes per connection on every tick, in order', (select per_tick from pd_res where label = 'bud1'), (select per_tick from pd_res where label = 'ref1'));
select t.is_true('   (there were pairs to compare)', (select count(*) from mc.visible) > 40);
select t.eq('   nothing waited (no tick left a joiner in the queue)', (select max_wait from pd_res where label = 'bud1'), 0);

------------------------------------------------------------------------------------------------ 2. over budget: joiners wait their turn
select t.pd_run('def1', 11, 30, 6, 3, 12, '1', 100.0);
select t.eq('three joiners a tick, one pairing a tick: the queue is 2, then 2+3-1, and drains by one a tick', (select qlen from pd_res where label = 'def1'), array[2, 4, 3, 2, 1, 0, 0, 0, 0, 0, 0, 0]);
select t.eq('   a queued joiner is nobody''s pair and nobody''s waypoint source', (select leaked from pd_res where label = 'def1'), 0);
select t.is_true('   it is not a no-op: the deferred run sent other frames tick by tick', (select per_tick from pd_res where label = 'def1') is distinct from (select per_tick from pd_res where label = 'ref1'));

------------------------------------------------------------------------------------------------ 3. and when the queue is empty the world is the same
select t.eq('the same mc.visible after the queue drained', (select vis from pd_res where label = 'def1'), (select vis from pd_res where label = 'ref1'));
select t.eq('the same locator connections', (select wp from pd_res where label = 'def1'), (select wp from pd_res where label = 'ref1'));
select t.eq('the same frames in all (every bundle and locator packet byte for byte; only the tick differs; first-pass repeats aside)', t.pd_cmp('def1', 'ref1'), 'same');
select t.pd_run('def2', 5, 80, 20, 5, 30, '1', 100.0);
select t.pd_run('ref2b', 5, 80, 20, 5, 30, 'off', 2.0);
select t.eq('80 online, 20 joiners 5 a tick, one a tick: same mc.visible', (select vis from pd_res where label = 'def2'), (select vis from pd_res where label = 'ref2b'));
select t.eq('   same locator connections', (select wp from pd_res where label = 'def2'), (select wp from pd_res where label = 'ref2b'));
select t.eq('   same frames in all', t.pd_cmp('def2', 'ref2b'), 'same');
select t.eq('   the queue drained one a tick', (select qlen from pd_res where label = 'def2'), array[4, 8, 12, 16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);

------------------------------------------------------------------------------------------------ 4. the budget lets several out when pairings are cheap, and nobody waits for ever
select t.pd_run('cheap', 5, 80, 20, 5, 30, '8', 2.0);
select t.is_true('a pairing that costs 2 ms against a budget of 8: four a tick, the fifth waits one tick (the average is learned from the run, so only the first tick is exact)', (select qlen from pd_res where label = 'cheap') [1] = 1);
select t.eq('   same mc.visible as the old behaviour', (select vis from pd_res where label = 'cheap'), (select vis from pd_res where label = 'ref2b'));
-- a queue that the free slot alone cannot drain in time: 40 joiners at once, 8 ticks of patience, one a tick
select t.pd_run('wait', 5, 20, 40, 40, 50, '1', 100.0);
select t.is_true('40 joiners in one tick are all paired (the queue is empty at the end: at least one per tick)', (select qlen from pd_res where label = 'wait') [50] = 0);

------------------------------------------------------------------------------------------------ 5. mutations: a deferral that leaves the queue out in fewer places than it has to is noticed
select t.pd_run('mut1', 11, 30, 6, 3, 12, '1', 100.0, 'vis_find');
select t.pd_run('mut2', 11, 30, 6, 3, 12, '1', 100.0, 'refresh');
select t.pd_run('mut3', 11, 30, 6, 3, 12, '1', 100.0, 'wp');
select t.pd_run('def1b', 11, 30, 6, 3, 12, '1', 100.0);
select t.eq('the unmutated run is reproducible (same seed, same bytes tick by tick)', (select per_tick from pd_res where label = 'def1b'), (select per_tick from pd_res where label = 'def1'));
select t.is_true('mutation: mc.vis_find does not leave the queue out: noticed (pairs of queued joiners, or other bytes)', (select leaked from pd_res where label = 'mut1') > 0 or (select per_tick from pd_res where label = 'mut1') <> (select per_tick from pd_res where label = 'def1'));
select t.is_true('mutation: the pair search takes queued joiners as partners: noticed', (select leaked from pd_res where label = 'mut2') > 0 or (select per_tick from pd_res where label = 'mut2') <> (select per_tick from pd_res where label = 'def1'));
select t.is_true('mutation: the locator pass gives queued joiners a transmit state: noticed', (select leaked from pd_res where label = 'mut3') > 0 or (select per_tick from pd_res where label = 'mut3') <> (select per_tick from pd_res where label = 'def1'));

update mc.server_property set value = '8' where key = 'dbcraft.pair-budget-ms'; update mc.server_property set value = 'off' where key = 'dbcraft.pair-tick-ms';
\else
select t.skip('no attribute reference data / static packets');
\endif
