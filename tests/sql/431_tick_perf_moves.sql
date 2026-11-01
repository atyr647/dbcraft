-- The fast movement path (sql/431) must do exactly what the original does: the same mc.player rows, the same bytes in every connection's queue, the same kicks,
-- the same counters.  Random scenarios are built, snapshotted, run through mc.apply_player_moves_general() (the original, kept verbatim), the state is
-- restored from the snapshot and run through mc.apply_player_moves(); everything is compared.  Scenario flavours: ordinary ticks, jumps of more than 10 blocks
-- (moved-too-quickly correction), teleport confirmations (right and wrong id), players already awaiting a teleport, positions changed by other code
-- (stored position differs from what viewers were told), rotation-only and status-only packets, several rotation packets per connection, NaN coordinates (kick),
-- and the inputs that must take the general path (two position packets, malformed lengths).

create or replace function t.build_moves(p_seed float8, p_flavour int, p_n int default 40) returns void language plpgsql as $$
declare i_pos int := mc.sid('move_player_pos'); i_pr int := mc.sid('move_player_pos_rot'); i_rot int := mc.sid('move_player_rot');
        i_st int := mc.sid('move_player_status_only'); i_te int := mc.sid('client_tick_end'); i_tp int := mc.sid('accept_teleportation');
        r record; k int; kind int; nx float8; nz float8; ny float8;
begin
  perform setseed(p_seed);
  truncate mc.play_out, mc.play_in, mc.play_in_work, mc.visible, mc.kick;
  delete from mc.player;
  insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, yaw, pitch, on_ground, chunk_x, chunk_z, sent_qx, sent_qy, sent_qz, sent_yaw, sent_pitch,
                         vis_dirty, last_sent_tick, teleport_id, awaiting_teleport)
  select md5((p_seed::text || i))::uuid, 'p' || i, i, 100 + i, px, py, pz, yw, pt, random() < .5, floor(px / 16)::int, floor(pz / 16)::int,
         mc.quant(px), mc.quant(py), mc.quant(pz), yw, pt, false, 90 + (random() * 9)::int, 5,
         case when p_flavour in (3, 4) and random() < .25 then 5 else null end
    from (select i, random() * 64 as px, 64 + random() * 4 as py, random() * 64 as pz, (random() * 360)::real as yw, (random() * 90 - 45)::real as pt from generate_series(1, p_n) i) g;
  -- positions changed by other code (a /tp): stored position differs from what the viewers were told
  if p_flavour = 5 then update mc.player set x = x + 3, z = z - 2 where entity_id % 5 = 0; end if;
  insert into mc.visible (viewer_eid, target_eid, viewer_conn)
  select a.entity_id, b.entity_id, a.conn_id from mc.player a join mc.player b on b.entity_id <> a.entity_id and abs(a.chunk_x - b.chunk_x) <= 2 and abs(a.chunk_z - b.chunk_z) <= 2;
  for r in select * from mc.player order by conn_id loop
    kind := (random() * 9)::int;
    nx := r.x + (random() - .5) * 0.8; ny := r.y; nz := r.z + (random() - .5) * 0.8;
    if p_flavour = 2 and random() < .2 then nx := r.x + 11 + random() * 20; end if;           -- too fast
    if p_flavour = 10 and random() < .3 then nx := r.x + 8.5 + random(); end if;               -- accepted (under 10 blocks) but over the 16-bit delta: teleport packet
    if p_flavour = 6 and random() < .1 then nx := 'NaN'; end if;                                -- kick
    if p_flavour = 7 and random() < .2 then nz := 'Infinity'; end if;
    if kind in (0, 1, 2, 3, 4) then   -- position + rotation
      insert into mc.play_in_work (conn_id, packet_id, body) values (r.conn_id, i_pr, proto.f64(nx) || proto.f64(ny) || proto.f64(nz) || proto.f32((r.yaw + 3)::real) || proto.f32(r.pitch) || set_byte('\x00'::bytea, 0, (random() < .5)::int));
    elsif kind in (5, 6) then          -- position only
      insert into mc.play_in_work (conn_id, packet_id, body) values (r.conn_id, i_pos, proto.f64(nx) || proto.f64(ny) || proto.f64(nz) || set_byte('\x00'::bytea, 0, (random() < .5)::int));
    elsif kind = 7 then                -- rotation only (sometimes several)
      for k in 1 .. 1 + (random() * 2)::int loop
        insert into mc.play_in_work (conn_id, packet_id, body) values (r.conn_id, i_rot, proto.f32((random() * 360)::real) || proto.f32((random() * 100 - 50)::real) || set_byte('\x00'::bytea, 0, (random() < .5)::int));
      end loop;
    elsif kind = 8 then                -- status only
      insert into mc.play_in_work (conn_id, packet_id, body) values (r.conn_id, i_st, set_byte('\x00'::bytea, 0, (random() < .5)::int));
    end if;                            -- kind 9: nothing but client_tick_end
    if p_flavour in (3, 4) and random() < .5 then          -- teleport confirmation, right or wrong id
      insert into mc.play_in_work (conn_id, packet_id, body) values (r.conn_id, i_tp, proto.varint(case when random() < .7 then 5 else 6 end) || proto.f64(r.x) || proto.f64(r.y) || proto.f64(r.z) || proto.f32(r.yaw) || proto.f32(r.pitch));
    end if;
    if p_flavour = 8 and random() < .2 then               -- two position packets: takes the general path
      insert into mc.play_in_work (conn_id, packet_id, body) values (r.conn_id, i_pos, proto.f64(nx) || proto.f64(ny) || proto.f64(nz) || '\x01'::bytea);
    end if;
    if p_flavour = 9 and random() < .2 then               -- a malformed length: takes the general path
      insert into mc.play_in_work (conn_id, packet_id, body) values (r.conn_id, i_pos, '\x0102');
    end if;
    insert into mc.play_in_work (conn_id, packet_id, body) values (r.conn_id, i_te, '\x');
  end loop;
end $$;

create or replace function t.snap_state() returns void language plpgsql as $$
begin
  drop table if exists t_s_player, t_s_in, t_s_vis;
  create table t_s_player as select * from mc.player;
  create table t_s_in as select * from mc.play_in_work;
  create table t_s_vis as select * from mc.visible;
end $$;
create or replace function t.restore_state() returns void language plpgsql as $$
begin
  truncate mc.play_out, mc.play_in, mc.play_in_work, mc.visible, mc.kick;
  delete from mc.player;
  insert into mc.player select * from t_s_player;
  insert into mc.play_in_work select * from t_s_in;
  insert into mc.visible select * from t_s_vis;
end $$;
-- everything that can differ, as one comparable text per component
create or replace function t.digest() returns table(what text, val text) language sql as $$
  select 'player', coalesce(string_agg(md5(p::text), ',' order by p.uuid), '') from mc.player p
  union all select 'out_per_conn', coalesce(string_agg(conn_id || ':' || md5(d), ',' order by conn_id), '')
              from (select conn_id, string_agg(encode(data, 'hex'), '|' order by seq) d from mc.play_out group by conn_id) q
  union all select 'kick', coalesce(string_agg(conn_id || ':' || encode(reason_nbt, 'hex'), ',' order by conn_id), '') from mc.kick
  union all select 'work_left', count(*)::text from mc.play_in_work $$;

create table if not exists t_res (seed float8, flavour int, which text, moved int, corrected int, kicked int, digest text);
create or replace function t.compare_moves(p_seed float8, p_flavour int) returns text language plpgsql as $$
declare ra record; rb record; da jsonb; db jsonb; diff text;
begin
  perform t.build_moves(p_seed, p_flavour); perform t.snap_state();
  select * into ra from mc.apply_player_moves_general(1000);
  select jsonb_object_agg(what, val) into da from t.digest();
  perform t.restore_state();
  select * into rb from mc.apply_player_moves(1000);
  select jsonb_object_agg(what, val) into db from t.digest();
  if (ra.moved, ra.corrected, ra.kicked) is distinct from (rb.moved, rb.corrected, rb.kicked) then
    return format('counters differ: general %s fast %s', ra, rb);
  end if;
  select string_agg(a.key, ',') into diff from jsonb_each_text(da) a join jsonb_each_text(db) b using (key) where a.value is distinct from b.value;
  if diff is not null then return 'differs in: ' || diff; end if;
  return 'same';
end $$;

select t.eq('flavour ' || f || ' seed ' || s, t.compare_moves(s / 10.0, f), 'same')
  from unnest(array[1, 2, 3, 4, 5, 6, 7, 8, 9, 10]) f, unnest(array[1, 2, 3]) s;
select t.eq('ordinary ticks, 20 more seeds', (select count(*) filter (where t.compare_moves(s::float8 / 100, 1) <> 'same') from generate_series(10, 29) s)::int, 0);
-- which path ran: the function call counters of the current transaction show whether the general version was called
set track_functions = 'all';
create or replace function t.general_calls() returns bigint language sql as $$
  select coalesce(pg_stat_get_xact_function_calls('mc.apply_player_moves_general(bigint)'::regprocedure), 0) $$;
do $$ declare before bigint; r record;
begin
  perform t.build_moves(0.3, 1);
  before := t.general_calls();
  select * into r from mc.apply_player_moves(1000);
  if t.general_calls() <> before then raise exception 'FAIL ordinary input fell back to the general path'; end if;
  raise notice 'ok   ordinary input stays on the fast path';
  perform t.build_moves(0.3, 8);                                  -- some connections send two position packets
  before := t.general_calls();
  select * into r from mc.apply_player_moves(1000);
  if t.general_calls() = before then raise exception 'FAIL two position packets did not take the general path'; end if;
  raise notice 'ok   two position packets take the general path';
  perform t.build_moves(0.3, 9);                                  -- a malformed length
  before := t.general_calls();
  select * into r from mc.apply_player_moves(1000);
  if t.general_calls() = before then raise exception 'FAIL a malformed packet did not take the general path'; end if;
  raise notice 'ok   a malformed packet takes the general path';
end $$;
