-- The dirty-driven locator bar (sql/908, docs/PERF-LOCATOR.md): mc.vis_wp_pass looks at the connections that can have an event, mc.vis_wp_pass_pairs (the reference: the pass of every
-- pair that was the server's until then) looks at all of them.  Both are run on the same state after every step of random walks (tiny steps, walking, jumps, teleports that do not set
-- last_move_tick, 3,000-block jumps), joins, leaves, crouching, game mode changes, hidden heads and view distance changes (up to 20 chunks, where a far connection can be inside the view),
-- the movement pass and the entity phase of every tick, and must produce the same packets (every receiver's bytes, in order), the same connections (kind and angle) and the same remembered
-- state.  A mutation check removes one way into the candidate set at a time (and changes two rules) and the same scenarios must notice.
select (select count(*) from ref.packet where state = 'play' and direction = 'clientbound' and name = 'minecraft:waypoint') > 0 as have_data \gset
\if :have_data

create or replace function t.wpd_digest() returns jsonb language sql as $$
  select jsonb_build_object(
    'out',   (select coalesce(string_agg(conn_id || ':' || md5(d), ',' order by conn_id), '') from (select conn_id, string_agg(encode(data, 'hex'), '|' order by seq) d from mc.play_out group by conn_id) q),
    'wp',    (select coalesce(string_agg(rcv || '>' || src || '=' || kind || '/' || coalesce(ang::text, ''), ',' order by rcv, src), '') from mc.wp),
    'cnt',   (select coalesce(string_agg(rcv || '=' || n, ',' order by rcv), '') from mc.wp_cnt where n > 0),
    'state', (select coalesce(string_agg(entity_id || '=' || coalesce(wp_state::text, 'n') || '/' || coalesce(wp_bx::text, 'n') || '/' || coalesce(wp_by::text, 'n') || '/' || coalesce(wp_bz::text, 'n') || '/'
                                         || coalesce(wp_cx::text, 'n') || '/' || coalesce(wp_cz::text, 'n'), ',' order by entity_id), '') from mc.player)) $$;

-- the waypoint packets in mc.play_out by operation and kind: frames are VarInt length | VarInt id (141: two bytes) | op | 0x01 | uuid | icon (19 bytes) | type
create table if not exists t.wpd_cov (op int, kind int, n bigint);
create or replace function t.wpd_count() returns void language plpgsql as $$
declare r record; d bytea; p int; len int; sh int; b int; st int;
begin
  for r in select data from mc.play_out loop
    d := r.data; p := 0;
    while p < length(d) loop
      len := 0; sh := 0;
      loop b := get_byte(d, p); p := p + 1; len := len | ((b & 127) << sh); sh := sh + 7; exit when b < 128; end loop;
      st := p;
      if get_byte(d, p) = 141 and get_byte(d, p + 1) = 1 then
        insert into t.wpd_cov values (get_byte(d, p + 2), get_byte(d, p + 2 + 1 + 1 + 16 + 19), 1);
      end if;
      p := st + len;
    end loop;
  end loop;
end $$;

-- a random requested view distance; only the scenarios that say so ask for 14+ chunks (set_config('t.wpd_bigvr', 'on', false)): from there on a far connection can be inside the view and every azimuth
-- connection is a candidate on every pass, which hides what the other ways into the candidate set do
create or replace function t.wpd_vr() returns int language sql volatile as $$
  select case when current_setting('t.wpd_bigvr', true) = 'on' then (array[null, 2, 4, 8, 10, 12, 16, 20])[1 + floor(random() * 8)::int] else (array[null, 2, 4, 8, 10, 12])[1 + floor(random() * 6)::int] end $$;

-- what a pass changes in the players: the remembered state (the snapshot is put back between the two runs)
create or replace function t.wpd_save() returns void language plpgsql as $$
begin
  drop table if exists t_wpd_p, t_wpd_w;
  create temp table t_wpd_p as select entity_id, wp_state, wp_bx, wp_by, wp_bz, wp_cx, wp_cz, wp_vr from mc.player;
  create temp table t_wpd_w as select * from mc.wp;
end $$;
create or replace function t.wpd_restore() returns void language plpgsql as $$
begin
  update mc.player p set wp_state = s.wp_state, wp_bx = s.wp_bx, wp_by = s.wp_by, wp_bz = s.wp_bz, wp_cx = s.wp_cx, wp_cz = s.wp_cz, wp_vr = s.wp_vr from t_wpd_p s where s.entity_id = p.entity_id;
  truncate mc.wp; insert into mc.wp select * from t_wpd_w;
  truncate mc.play_out;
end $$;

-- one pass of both functions from the same state; the state afterwards is the dirty-driven one's.  Returns '' when they agree, else the names of what differs.
create or replace function t.wpd_both(p_fn text, p_cur bigint, p_phase int, p_n int) returns text language plpgsql as $$
declare da jsonb; db jsonb; diff text;
begin
  perform t.wpd_save(); truncate mc.play_out;
  perform mc.vis_wp_pass_pairs(p_cur, p_phase, p_n); da := t.wpd_digest();
  perform t.wpd_restore();
  execute format('select %s($1, $2, $3)', p_fn) using p_cur, p_phase, p_n; db := t.wpd_digest();
  if p_fn = 'mc.vis_wp_pass' then perform t.wpd_count(); end if;
  select string_agg(a.key, ',') into diff from jsonb_each_text(da) a join jsonb_each_text(db) b using (key) where a.value is distinct from b.value;
  return coalesce(diff, '');
end $$;

-- the world: n players spread over `spread` blocks.  Everybody is new to the pass, connected by the reference (so both start from what the server has after its own passes).
create or replace function t.wpd_world(p_seed float8, p_n int, p_spread int) returns void language plpgsql as $$
begin
  perform setseed(p_seed / 100.0);
  update mc.game_rule set value = 'true' where name = 'minecraft:locator_bar';
  update mc.server_property set value = '100000' where key = 'dbcraft.locator-bar-max-players';
  update mc.server_property set value = '24' where key = 'view-distance';
  truncate mc.play_out, mc.wp; delete from mc.player;
  insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, chunk_x, chunk_z, gamemode)
  select md5(p_seed::text || i)::uuid, 'w' || i, i, 1000 + i, px, 64 + (random() * 3)::int, pz, floor(px / 16)::int, floor(pz / 16)::int, case when random() < 0.08 then 3 else 1 end
    from (select i, random() * p_spread - p_spread / 2 as px, random() * p_spread - p_spread / 2 as pz from generate_series(1, p_n) i) g;
  update mc.player set last_move_tick = 1001, view_distance_req = t.wpd_vr() where conn_id is not null;
  update mc.player set wp_hidden = true where random() < 0.05;
  perform mc.vis_wp_pass_pairs(1000, 2, p_n);
  perform mc.vis_wp_pass_pairs(1001, 1, p_n);
  truncate mc.play_out;
end $$;

-- one tick of random events, then both passes of the tick (movement, entity phase) compared.  p_move: probability that a player moves, p_big: of those, that it jumps, p_chg: state changes
create or replace function t.wpd_tick(p_fn text, p_cur bigint, p_move float8, p_big float8, p_chg float8) returns text language plpgsql as $$
declare r text; res text := ''; n int; e int;
begin
  -- joins and leaves (the network phase: vis_wp_join; the rows of a leaver go)
  if random() < p_chg * 4 then
    e := 2000 + (random() * 100000)::int;
    insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, chunk_x, chunk_z, gamemode)
    select gen_random_uuid(), 'j' || e, e, e, px, 64, pz, floor(px / 16)::int, floor(pz / 16)::int, case when random() < 0.2 then 3 else 1 end
      from (select (select avg(x) from mc.player) + random() * 400 - 200 as px, (select avg(z) from mc.player) + random() * 400 - 200 as pz) g
    on conflict do nothing;
    update mc.player set view_distance_req = t.wpd_vr(), last_move_tick = case when random() < 0.5 then p_cur end where entity_id = e;
    perform mc.vis_wp_join(e);
  end if;
  if random() < p_chg * 3 then
    update mc.player set conn_id = null where entity_id = (select entity_id from mc.player where conn_id is not null order by random() limit 1);
    delete from mc.wp where src not in (select entity_id from mc.player where conn_id is not null) or rcv not in (select entity_id from mc.player where conn_id is not null);
  end if;
  truncate mc.play_out;
  select count(*)::int into n from mc.player where conn_id is not null;
  -- movement: tiny steps (inside a block), walking, jumps of a few blocks to 1,500 blocks; 6 % of the moves are teleports: no last_move_tick, vis_dirty (sql/813)
  update mc.player p set x = q.nx, z = q.nz, y = q.ny, chunk_x = floor(q.nx / 16)::int, chunk_z = floor(q.nz / 16)::int,
         last_move_tick = case when q.silent then p.last_move_tick else p_cur end,
         vis_dirty = p.vis_dirty or q.silent       -- (a move without a movement packet is a teleport: /tp sets vis_dirty)
    from (select entity_id, x + dx as nx, z + dz as nz, y + (case when random() < 0.1 then (random() * 6 - 3)::int else 0 end) as ny, random() < 0.06 as silent
            from (select entity_id, x, y, z,
                         case when random() < p_big then (random() - 0.5) * (case when random() < 0.3 then 3000 else 40 end) when random() < 0.3 then (random() - 0.5) * 0.4 else (random() - 0.5) * 1.6 end as dx,
                         case when random() < p_big then (random() - 0.5) * (case when random() < 0.3 then 3000 else 40 end) when random() < 0.3 then (random() - 0.5) * 0.4 else (random() - 0.5) * 1.6 end as dz
                    from mc.player where conn_id is not null and random() < p_move) a) q
   where p.entity_id = q.entity_id;
  if random() < p_chg then update mc.player set view_distance_req = t.wpd_vr() where conn_id is not null and random() < 0.2; end if;
  r := t.wpd_both(p_fn, p_cur, 1, n); if r <> '' then res := res || ' tick ' || p_cur || ' movement: ' || r; end if;
  -- the entity phase: crouching, game modes, hidden heads
  update mc.player set pose = case when pose = 5 then 0 else 5 end where conn_id is not null and random() < p_chg * 2;
  update mc.player set gamemode = case when gamemode = 3 then 1 else 3 end where conn_id is not null and random() < p_chg;
  update mc.player set wp_hidden = not wp_hidden where conn_id is not null and random() < p_chg;
  truncate mc.play_out;
  r := t.wpd_both(p_fn, p_cur, 2, n); if r <> '' then res := res || ' tick ' || p_cur || ' entity phase: ' || r; end if;
  return res;
end $$;

-- a scenario of p_ticks ticks; returns the first difference, '' when the passes agree throughout
create or replace function t.wpd_run(p_fn text, p_seed float8, p_n int, p_spread int, p_ticks int, p_move float8, p_big float8, p_chg float8) returns text language plpgsql as $$
declare i int; r text;
begin
  perform t.wpd_world(p_seed, p_n, p_spread);
  for i in 1 .. p_ticks loop
    r := t.wpd_tick(p_fn, 1001 + i, p_move, p_big, p_chg);
    if r <> '' then return r; end if;
  end loop;
  return '';
end $$;

truncate t.wpd_cov;
select set_config('t.wpd_bigvr', 'off', false);
select t.eq('small world (300 blocks: block and chunk connections), walking: seed ' || s || ', 30 players, 40 ticks', t.wpd_run('mc.vis_wp_pass', s, 30, 300, 40, 0.6, 0.02, 0.05), '') from generate_series(1, 4) s;
select t.eq('wide world (2,500 blocks: azimuth connections), walking: seed ' || s || ', 30 players, 40 ticks', t.wpd_run('mc.vis_wp_pass', 10 + s, 30, 2500, 40, 0.6, 0.02, 0.05), '') from generate_series(1, 4) s;
select t.eq('mixed world (900 blocks), many jumps and state changes: seed ' || s || ', 40 players, 40 ticks', t.wpd_run('mc.vis_wp_pass', 20 + s, 40, 900, 40, 0.8, 0.15, 0.15), '') from generate_series(1, 4) s;
select t.eq('few players, mostly standing still: seed ' || s || ', 12 players, 60 ticks', t.wpd_run('mc.vis_wp_pass', 30 + s, 12, 600, 60, 0.1, 0.03, 0.08), '') from generate_series(1, 3) s;
select t.eq('crowd in one place (64 blocks) and walking: seed ' || s || ', 40 players, 30 ticks', t.wpd_run('mc.vis_wp_pass', 40 + s, 40, 64, 30, 0.9, 0.01, 0.05), '') from generate_series(1, 2) s;
select set_config('t.wpd_bigvr', 'on', false);
select t.eq('view distances up to 20 chunks (a far connection can be inside the view): seed ' || s || ', 30 players, 40 ticks', t.wpd_run('mc.vis_wp_pass', 50 + s, 30, case s when 1 then 700 else 1500 end, 40, 0.7, 0.08, 0.1), '') from generate_series(1, 3) s;
select set_config('t.wpd_bigvr', 'off', false);

-- the scenarios were not empty: packets of every operation and kind were sent
select t.is_true('the scenarios sent a TRACK of every kind (block, chunk, azimuth)', (select count(distinct kind) from t.wpd_cov where op = 0 and kind in (1, 2, 3)) = 3);
select t.is_true('...an UPDATE of every kind', (select count(distinct kind) from t.wpd_cov where op = 2 and kind in (1, 2, 3)) = 3);
select t.is_true('...and UNTRACKs', (select coalesce(sum(n), 0) from t.wpd_cov where op = 1) > 0);

-- mutation check: the function with one way into the candidate set removed (or a rule changed) must be noticed by the scenarios
create or replace function t.wpd_detects(p_find text, p_repl text) returns boolean language plpgsql as $$
declare def text := replace(pg_get_functiondef('mc.vis_wp_pass(bigint, int, int)'::regprocedure), 'mc.vis_wp_pass(', 'mc.vis_wp_pass_mut('); m text; s int;
begin
  m := replace(def, p_find, p_repl);
  if m = def then raise exception 'the mutation did not apply: %', p_find; end if;
  execute m;
  for s in 1 .. 6 loop
    if t.wpd_run('mc.vis_wp_pass_mut', s, 30, case s % 3 when 0 then 300 when 1 then 2500 else 900 end, 40, 0.7, 0.08, 0.1) <> '' then return true; end if;
  end loop;
  return false;
end $$;
select t.is_true('mutation: kind-1 rows of a source that changed block are not looked at -> noticed', t.wpd_detects('w.kind = 1 and w.src = any(', 'w.kind = 1 and false and w.src = any('));
select t.is_true('mutation: kind-2 rows of a source that changed chunk are not looked at -> noticed', t.wpd_detects('w.kind = 2 and w.src = any(', 'w.kind = 2 and false and w.src = any('));
select t.is_true('mutation: kind-2 rows of a receiver that changed chunk or view are not looked at -> noticed', t.wpd_detects('w.kind = 2 and w.rcv = any(', 'w.kind = 2 and false and w.rcv = any('));
select t.is_true('mutation: azimuth rows of a source that moved are not looked at -> noticed', t.wpd_detects('w.kind = 3 and w.src = any(', 'w.kind = 3 and false and w.src = any('));
select t.is_true('mutation: azimuth rows of a receiver that moved are not looked at -> noticed', t.wpd_detects('w.kind = 3 and w.rcv = any(', 'w.kind = 3 and false and w.rcv = any('));
select t.is_true('mutation: the rows of a player the pass has not seen are not looked at -> noticed', t.wpd_detects('(select fset is not null from sets) and w.rcv = any(', '(select fset is not null from sets) and false and w.rcv = any('));
select t.is_true('mutation: the connections a mover is missing are not made -> noticed', t.wpd_detects('p_phase = 1 and (select dset is not null from sets)', 'p_phase = 1 and false and (select dset is not null from sets)'));
select t.is_true('mutation: the entity phase looks at the pairs of a changed player only as a receiver -> noticed',
                 t.wpd_detects('(r.eid = any(coalesce((select sset from sets), ''{}''::int[])) or s.eid = any(coalesce((select sset from sets), ''{}''::int[])))', '(r.eid = any(coalesce((select sset from sets), ''{}''::int[])))'));
select t.is_true('mutation: a block that changed by more than one is an update, not a remake -> noticed', t.wpd_detects('when ok = 1 and manh > 1 then ''remake''', 'when ok = 1 and manh > 1 then ''update'''));
select t.is_true('mutation: the angle threshold is a degree, not half a degree -> noticed', t.wpd_detects('> 0.008726646::real then ''update''', '> 0.017453292::real then ''update'''));
select t.is_true('mutation: a view distance change does not look at the chunk connections of the receiver -> noticed',
                 t.wpd_detects('array_agg(eid) filter (where cheb > 0 or ovr is distinct from vr) as vcset', 'array_agg(eid) filter (where cheb > 0) as vcset'));
select set_config('t.wpd_bigvr', 'on', false);
select t.is_true('mutation: the view of 14+ chunks does not make every azimuth connection a candidate -> noticed', t.wpd_detects('coalesce(max(vr) >= 14, false) as slow', 'false as slow'));
select set_config('t.wpd_bigvr', 'off', false);
drop function if exists mc.vis_wp_pass_mut(bigint, int, int);

-- restore the settings the scenarios changed
update mc.server_property set value = '10' where key = 'view-distance';
truncate mc.play_out, mc.wp; delete from mc.player;
\else
select 'skipped: no packet reference data' as skipped;
\endif
