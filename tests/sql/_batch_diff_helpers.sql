-- Shared by tests/sql/387 and 388: state generation, random traffic, snapshot/restore and canonical capture for the batched-vs-baseline differential tests.

------------------------------------------------------------------------------------------------ state generation
create or replace function t.bfresh() returns void language plpgsql as $$
begin
    truncate net.conn, net.inbox, net.outbox, net.play_inbox, net.batch;
    truncate mc.play_out, mc.play_in, mc.play_in_work, mc.visible, mc.kick, mc.pending_ack, mc.block_actor, mc.block_event, mc.error_log, mc.tick_log, mc.server_tick_log;
    delete from mc.player; delete from mc.op; delete from mc.whitelist; delete from mc.ban;
    perform mc.configure_dev_server('test', 'creative');
    update mc.server_property set value = '2' where key in ('view-distance', 'simulation-distance');
    update mc.server_property set value = '100' where key = 'max-players';
    update mc.server_property set value = 'false' where key = 'white-list';
    update mc.game_state set game_time = 100, day_time = 100;
    perform mc.reset_dev_world(4);
    -- a world big enough that no chunk has to be generated while streaming (generation in the first run would make the second run's world different)
    perform mc.generate_flat_area('minecraft:overworld', -10, -10, 10, 10);
    perform mc.chunk_packet('minecraft:overworld', x, z) from generate_series(-10, 10) x, generate_series(-10, 10) z;
end $$;

-- n players in a small area (chunks -2..2), ~1 in 11 offline; sent_* sometimes differ from the position (so movement packets are due), some awaiting a teleport confirmation
create or replace function t.gen_state(n int, p_whole boolean) returns void language plpgsql as $$
begin
    truncate mc.play_out, mc.play_in, mc.play_in_work, mc.visible, mc.kick, mc.pending_ack, mc.block_actor, mc.block_event, mc.error_log, mc.tick_log, mc.server_tick_log;
    truncate net.conn, net.inbox, net.outbox, net.play_inbox, net.batch;
    delete from mc.player;
    insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, yaw, pitch, on_ground, chunk_x, chunk_z, sent_qx, sent_qy, sent_qz, sent_yaw, sent_pitch, last_sent_tick,
                           teleport_id, awaiting_teleport, vis_dirty, gamemode, keepalive_sent_tick)
    select md5('b' || i::text)::uuid, 'p' || i, case when i % 11 = 0 then null else 1000 + i end, case when i % 11 = 0 then null else i end,
           px, -60, pz, yaw, pitch, random() < 0.5, floor(px / 16)::int, floor(pz / 16)::int,
           mc.quant(px) + case when random() < 0.3 then (random() * 8000 - 4000)::int when random() < 0.05 then 40000 else 0 end, mc.quant(-60.0) + case when random() < 0.1 then 123 else 0 end,
           mc.quant(pz) + case when random() < 0.3 then (random() * 8000 - 4000)::int else 0 end,
           case when random() < 0.7 then yaw else yaw + 5 end, pitch, (random() * 90)::int, (random() * 5)::int,
           null, random() < 0.2, 1, 0
      from (select i, (random() * 80 - 40) as px, (random() * 80 - 40) as pz, (random() * 360)::real as yaw, (random() * 40 - 20)::real as pitch from generate_series(1, n) i) g;
    update mc.player set awaiting_teleport = teleport_id where random() < 0.15 and conn_id is not null;
    insert into mc.visible (viewer_eid, target_eid, viewer_conn)
    select a.entity_id, b.entity_id, a.conn_id from mc.player a join mc.player b on b.entity_id <> a.entity_id and abs(a.chunk_x - b.chunk_x) <= 2 and abs(a.chunk_z - b.chunk_z) <= 2
     where a.conn_id is not null and b.conn_id is not null;     -- consistent with the rule (mc.visible is a cache of it; sql/468 recomputes only the pairs that change)
    if p_whole then
        insert into net.conn (conn_id, state, name, uuid, compression, entity_id, view_cx, view_cz, gamemode)
        select conn_id, 'play', name, uuid, -1, entity_id,
               chunk_x + case when random() < 0.12 then 1 when random() < 0.12 then -1 else 0 end, chunk_z + case when random() < 0.12 then 1 else 0 end, gamemode
          from mc.player where conn_id is not null;
    end if;
    update mc.game_state set game_time = 100, day_time = 100;
end $$;

------------------------------------------------------------------------------------------------ random traffic
-- t.script(tk, conn_id, ord, payload): the frames a gateway would insert into net.inbox before tick tk
create table if not exists t.script (tk int, conn_id bigint, ord int, payload bytea);
drop function if exists t.gen_script(int, boolean);
create or replace function t.gen_script(n_ticks int, p_cold boolean, p_single_bad boolean default false) returns void language plpgsql as $$
declare r record; tk int; k int; ord int; pk_pos int := mc.sid('move_player_pos'); pk_pr int := mc.sid('move_player_pos_rot'); pk_rot int := mc.sid('move_player_rot');
        pk_st int := mc.sid('move_player_status_only'); pk_te int := mc.sid('client_tick_end'); pk_tp int := mc.sid('accept_teleportation'); pk_ka int := mc.sid('keep_alive');
        pk_cb int := mc.sid('chunk_batch_received');
        dx float8; dz float8; flags int; bad_conn bigint; is_bad boolean; cur_tk int;
begin
    truncate t.script;
    for tk in 1..n_ticks loop
        cur_tk := tk;
        -- p_single_bad: at most ONE connection per tick may do something that gets it disconnected, so at most one connection closes per tick
        select conn_id into bad_conn from mc.player where conn_id is not null order by random() limit 1;
        for r in select conn_id, x, y, z, yaw, pitch, teleport_id, awaiting_teleport from mc.player where conn_id is not null order by conn_id loop
            ord := 0; k := (random() * 100)::int;
            is_bad := k in (67, 68, 69, 73, 74, 75, 76, 77, 82, 83, 97);      -- the categories below that get the connection disconnected
            if p_single_bad and is_bad and r.conn_id <> bad_conn then k := 10; end if; dx := (random() - 0.5) * 0.8; dz := (random() - 0.5) * 0.8; flags := (random() * 2)::int;
            -- helper: add a frame
            if k < 14 then null;                                                                                                      -- silent client
            elsif k < 24 then insert into t.script values (tk, r.conn_id, 1, proto.varint(pk_te));                                      -- tick end only
            elsif k < 46 then                                                                                                          -- pos + tick end
                insert into t.script values (tk, r.conn_id, 1, proto.varint(pk_pos) || proto.f64(r.x + dx) || proto.f64(r.y) || proto.f64(r.z + dz) || set_byte('\x00'::bytea, 0, flags)),
                                            (tk, r.conn_id, 2, proto.varint(pk_te));
            elsif k < 60 then                                                                                                          -- pos_rot + tick end
                insert into t.script values (tk, r.conn_id, 1, proto.varint(pk_pr) || proto.f64(r.x + dx) || proto.f64(r.y) || proto.f64(r.z + dz) || proto.f32((r.yaw + (random() * 30))::real) || proto.f32(r.pitch) || set_byte('\x00'::bytea, 0, flags)),
                                            (tk, r.conn_id, 2, proto.varint(pk_te));
            elsif k < 64 then insert into t.script values (tk, r.conn_id, 1, proto.varint(pk_rot) || proto.f32((r.yaw + 10)::real) || proto.f32((random() * 200 - 100)::real) || set_byte('\x00'::bytea, 0, flags));   -- rotation only (pitch may exceed 90)
            elsif k < 67 then insert into t.script values (tk, r.conn_id, 1, proto.varint(pk_st) || set_byte('\x00'::bytea, 0, flags));                                                                          -- status only
            elsif k < 70 then                                                                                                          -- two position packets before a tick end: kicked
                insert into t.script values (tk, r.conn_id, 1, proto.varint(pk_pos) || proto.f64(r.x + dx) || proto.f64(r.y) || proto.f64(r.z) || '\x01'::bytea),
                                            (tk, r.conn_id, 2, proto.varint(pk_pr) || proto.f64(r.x) || proto.f64(r.y) || proto.f64(r.z + dz) || proto.f32(r.yaw) || proto.f32(r.pitch) || '\x01'::bytea);
            elsif k < 73 then                                                                                                          -- two position packets, each followed by a tick end: legal
                insert into t.script values (tk, r.conn_id, 1, proto.varint(pk_pos) || proto.f64(r.x + dx) || proto.f64(r.y) || proto.f64(r.z) || '\x01'::bytea),
                                            (tk, r.conn_id, 2, proto.varint(pk_te)),
                                            (tk, r.conn_id, 3, proto.varint(pk_pos) || proto.f64(r.x + dx * 2) || proto.f64(r.y) || proto.f64(r.z + dz) || '\x00'::bytea),
                                            (tk, r.conn_id, 4, proto.varint(pk_te));
            elsif k < 76 then insert into t.script values (tk, r.conn_id, 1, proto.varint(pk_pos) || proto.f64('NaN'::float8) || proto.f64(r.y) || proto.f64(r.z) || '\x01'::bytea);                -- NaN: kicked
            elsif k < 78 then insert into t.script values (tk, r.conn_id, 1, proto.varint(pk_pr) || proto.f64(r.x) || proto.f64(r.y) || proto.f64(r.z) || proto.f32('Infinity'::real) || proto.f32(0) || '\x01'::bytea);   -- infinite yaw: kicked
            elsif k < 82 then                                                                                                          -- moved too quickly (11..40 blocks): corrected
                insert into t.script values (tk, r.conn_id, 1, proto.varint(pk_pos) || proto.f64(r.x + 11 + random() * 29) || proto.f64(r.y) || proto.f64(r.z) || '\x01'::bytea), (tk, r.conn_id, 2, proto.varint(pk_te));
            elsif k < 84 then insert into t.script values (tk, r.conn_id, 1, proto.varint(pk_pos) || '\x00112233445566778899aabbccddeeff'::bytea);                                                      -- malformed length (16 bytes): kicked
            elsif k < 90 then                                                                                                          -- confirmation (right, wrong or none for the tick) then a position
                insert into t.script values (tk, r.conn_id, 1, proto.varint(pk_tp) || proto.varint(case when random() < 0.7 then coalesce(r.awaiting_teleport, r.teleport_id) else (random() * 9)::int end) || proto.f64(r.x) || proto.f64(r.y) || proto.f64(r.z) || proto.f32(r.yaw) || proto.f32(r.pitch)),
                                            (tk, r.conn_id, 2, proto.varint(pk_pr) || proto.f64(r.x + dx) || proto.f64(r.y) || proto.f64(r.z + dz) || proto.f32(r.yaw) || proto.f32(r.pitch) || '\x01'::bytea),
                                            (tk, r.conn_id, 3, proto.varint(pk_te));
            elsif k < 92 then insert into t.script values (tk, r.conn_id, 1, proto.varint(pk_pr) || proto.f64(-4.0e7) || proto.f64(3.0e7) || proto.f64(r.z) || proto.f32(r.yaw) || proto.f32(r.pitch) || '\x00'::bytea), (tk, r.conn_id, 2, proto.varint(pk_te));  -- far out: too fast, clamped values never applied
            elsif k < 95 and p_cold then insert into t.script values (tk, r.conn_id, 1, proto.varint(pk_ka) || proto.i64((random() * 1000)::bigint));                                               -- keep-alive answer
            elsif k < 97 and p_cold then insert into t.script values (tk, r.conn_id, 1, proto.varint(pk_cb) || proto.f32(20.0));                                                                   -- chunk batch received (cold path)
            elsif k < 98 and p_cold then insert into t.script values (tk, r.conn_id, 1, proto.varint(250) || '\x01'::bytea);                                                                         -- unknown packet id: the connection is closed
            else insert into t.script values (tk, r.conn_id, 1, proto.varint(pk_te));
            end if;
        end loop;
        -- an occasional frame for a connection nobody knows (ignored by both)
        if p_cold and random() < 0.3 then insert into t.script values (tk, 99999, 1, proto.varint(pk_te)); end if;
        -- a player who walks a whole chunk in one tick (never "too fast" below 10 blocks: 9 blocks) crosses chunk borders: chunk streaming and visibility changes
        if random() < 0.5 then
            insert into t.script
            select tk, p.conn_id, 50, proto.varint(pk_pos) || proto.f64(p.x + 9.5 * (case when random() < 0.5 then 1 else -1 end)) || proto.f64(p.y) || proto.f64(p.z) || '\x01'::bytea
              from mc.player p where p.conn_id is not null order by random() limit 3;
            -- tick ends around the walk, so it is a legal single position in its own segment for a connection that sent one before
            insert into t.script select cur_tk, s.conn_id, 49, proto.varint(pk_te) from t.script s where s.tk = cur_tk and s.ord = 50;
            insert into t.script select cur_tk, s.conn_id, 51, proto.varint(pk_te) from t.script s where s.tk = cur_tk and s.ord = 50;
        end if;
    end loop;
end $$;

------------------------------------------------------------------------------------------------ snapshot, restore, capture
create or replace function t.snap() returns void language plpgsql as $$
begin
    drop table if exists t.s_player, t.s_visible, t.s_conn, t.s_gs;
    create table t.s_player as select * from mc.player;
    create table t.s_visible as select * from mc.visible;
    create table t.s_conn as select * from net.conn;
    create table t.s_gs as select * from mc.game_state;
end $$;
create or replace function t.restore() returns void language plpgsql as $$
begin
    truncate mc.play_out, mc.play_in, mc.play_in_work, mc.visible, mc.kick, mc.pending_ack, mc.block_actor, mc.block_event, mc.error_log, mc.tick_log, mc.server_tick_log;
    truncate net.conn, net.inbox, net.outbox, net.play_inbox, net.batch;
    delete from mc.player;
    insert into mc.player select * from t.s_player;
    insert into mc.visible select * from t.s_visible;
    insert into net.conn select * from t.s_conn;
    update mc.game_state set game_time = g.game_time, day_time = g.day_time from t.s_gs g;
end $$;

-- the outbound frames of one connection as an array: a remove_entities packet's id list is sorted (its order is undefined in the baseline)
create or replace function t.canon_frames(b bytea) returns text[] language plpgsql as $$
declare o int := 0; v int; n int; id int; fr bytea; out text[] := '{}'; body bytea; cnt int; ids int[]; i int; p int; rm int := mc.pid('remove_entities');
begin
    while o < length(b) loop
        select val, nxt into v, n from proto.varint_read(b, o);
        fr := substring(b from n + 1 for v);                       -- id + body
        select val into id from proto.varint_read(fr, 0);
        if id = rm then
            body := substring(fr from (select nxt from proto.varint_read(fr, 0)) + 1);
            select val, nxt into cnt, p from proto.varint_read(body, 0);
            ids := '{}';
            for i in 1..cnt loop select val, nxt into v, p from proto.varint_read(body, p); ids := ids || v; end loop;
            out := out || ('rm:' || (select string_agg(x::text, ',' order by x) from unnest(ids) x));
        else
            out := out || encode(fr, 'hex');
        end if;
        o := n + length(fr);
    end loop;
    return out;
end $$;
create or replace function t.canon(b bytea) returns text language sql as $$ select array_to_string(t.canon_frames(b), '/') $$;
create or replace function t.canon_set(b bytea) returns text language sql as $$ select array_to_string(array(select f from unnest(t.canon_frames(b)) f order by f), '/') $$;

create or replace function t.cap_players() returns text language sql as $$
    select coalesce(string_agg(concat_ws('|', uuid, conn_id, entity_id, x, y, z, yaw, pitch, on_ground, chunk_x, chunk_z, vis_dirty, teleport_id, awaiting_teleport,
                                         sent_qx, sent_qy, sent_qz, sent_yaw, sent_pitch, last_sent_tick, keepalive_id, keepalive_sent_tick, latency_ms), E'\n' order by uuid), '') from mc.player $$;
create or replace function t.cap_visible() returns text language sql as $$
    select coalesce(string_agg(viewer_eid || '>' || target_eid, ',' order by viewer_eid, target_eid), '') from mc.visible $$;
-- game queue contents per connection (Part A reads mc.play_out directly)
create or replace function t.cap_play_out() returns text language sql as $$
    select coalesce(string_agg(conn_id || ':' || t.canon(h), E'\n' order by conn_id), '')
      from (select conn_id, string_agg(data, ''::bytea order by seq) h from mc.play_out group by conn_id) q $$;
create or replace function t.cap_kick() returns text language sql as $$ select coalesce(string_agg(conn_id::text, ',' order by conn_id), '') from mc.kick $$;
-- what the gateway would receive (Part B): drain_outbox per connection, once, rendered in order (seq) and unordered (set); and how many connections close
drop function if exists t.cap_drain();
drop function if exists t.cap_drain(boolean);
create temp table if not exists _dr (conn_id bigint, data bytea, close boolean);
create or replace function t.cap_drain(p_ref boolean default false, out seq_txt text, out set_txt text, out surv_txt text, out closes_txt text, out n_close int) language plpgsql as $$
begin
    delete from _dr;
    if p_ref then insert into _dr select * from net.drain_outbox_ref(); else insert into _dr select * from net.drain_outbox(); end if;
    select coalesce(string_agg(conn_id || ':' || t.canon(data) || ':' || close::text, E'\n' order by conn_id), ''),
           coalesce(string_agg(conn_id || ':' || t.canon_set(data) || ':' || close::text, E'\n' order by conn_id), ''),
           coalesce(string_agg(conn_id || ':' || t.canon_set(data), E'\n' order by conn_id) filter (where not close), ''),
           coalesce(string_agg(conn_id::text, ',' order by conn_id) filter (where close), ''), count(*) filter (where close)::int
      into seq_txt, set_txt, surv_txt, closes_txt, n_close from _dr;
end $$;
create or replace function t.cap_conn() returns text language sql as $$
    select coalesce(string_agg(concat_ws('|', conn_id, state, closing, view_cx, view_cz, compression), E'\n' order by conn_id), '') from net.conn $$;

create table if not exists t.caps (trial int, impl text, tk int, what text, txt text);
-- first difference between two captures: first differing line, then the first differing '/'-separated frame in it, then the first differing character in that frame
create or replace function t.first_diff(a text, b text) returns text language plpgsql as $$
declare ln int; x text; y text; fr int; fx text; fy text; off int;
begin
    select coalesce(l.n, r.n), l.x, r.y into ln, x, y
      from (select ord::int as n, v as x from string_to_table(a, E'\n') with ordinality s(v, ord)) l
      full join (select ord::int as n, v as y from string_to_table(b, E'\n') with ordinality s(v, ord)) r on r.n = l.n
     where l.x is distinct from r.y order by coalesce(l.n, r.n) limit 1;
    if ln is null then return 'no difference'; end if;
    select coalesce(l.n, r.n), l.v, r.v into fr, fx, fy
      from (select ord::int as n, v from string_to_table(coalesce(x, ''), '/') with ordinality s(v, ord)) l
      full join (select ord::int as n, v from string_to_table(coalesce(y, ''), '/') with ordinality s(v, ord)) r on r.n = l.n
     where l.v is distinct from r.v order by coalesce(l.n, r.n) limit 1;
    if fr is null then return 'line ' || ln || ' differs outside frames: ' || left(coalesce(x, '<none>'), 120) || ' | ' || left(coalesce(y, '<none>'), 120); end if;
    select coalesce(min(i), 1) into off from generate_series(1, greatest(length(coalesce(fx, '')), length(coalesce(fy, '')))) i where substr(coalesce(fx, ''), i, 1) <> substr(coalesce(fy, ''), i, 1);
    return 'line ' || ln || ' (' || left(x, 14) || '...) frame ' || fr || ' char ' || off || E': baseline = ...' || substr(coalesce(fx, '<none>'), greatest(off - 40, 1), 120)
           || E'\n  batched  = ...' || substr(coalesce(fy, '<none>'), greatest(off - 40, 1), 120);
end $$;

