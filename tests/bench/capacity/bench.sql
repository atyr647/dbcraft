-- Moving-player capacity bench (docs/PERF-CAPACITY.md): the whole server tick (net.inbox -> mc.server_tick -> net.drain_outbox) for N players that WALK like the scoreboard's
-- load generator (tools/scoreboard/loadgen.py): 4.317 blocks/s along a heading that changes every 3-8 s, kept inside +-bound blocks, one move_player_pos per client tick
-- (and a client_tick_end between two of them when a client sends several per tick, which is what the gateway passes on), keep-alive answers, teleport confirmations.
-- It builds on tests/bench/integration/bench.sql (ibench.*) and tests/bench/tick/cpu.sql (tickbench.*: per-tick on-CPU time from /proc/self/schedstat).
create schema if not exists capb;
create unlogged table if not exists capb.walk (conn_id int primary key, heading float8 not null, turn_at bigint not null);

-- n players over a square of `side` chunks (centred on the origin), view distance p_view; every chunk of the area plus the view radius must exist (capb.world)
create or replace function capb.setup(n int, side int, p_view int default 10) returns void language plpgsql as $$
begin
  perform ibench.setup(n, side, p_view);
  -- ibench.setup places the players in [0, side*16): centre them on the origin like the scoreboard (and so inside the pre-generated world)
  update mc.player set x = x - side * 8, z = z - side * 8, chunk_x = floor((x - side * 8) / 16)::int, chunk_z = floor((z - side * 8) / 16)::int,
         sent_qx = mc.quant(x - side * 8), sent_qz = mc.quant(z - side * 8) where conn_id is not null;
  update net.conn c set view_cx = p.chunk_x, view_cz = p.chunk_z from mc.player p where p.conn_id = c.conn_id;
  -- ibench.setup resets the game clock to 0 AFTER the join trigger stamped trk_start with the old clock: the tracker would not look at anybody until the clock caught up.  The players here have
  -- been in play for a while (a random phase of the tracker's two-tick cycle, nothing pending from the join)
  update mc.player set trk_start = floor(random() * 2)::int, trk_first = false, vis_wake = 0 where conn_id is not null;
  truncate capb.walk;
  insert into capb.walk select conn_id, random() * 2 * pi(), (60 + random() * 100)::int from mc.player where conn_id is not null;
end $$;

-- the pre-generated world: chunks -r .. r in both directions generated, their packets cached (a never-sent chunk costs 5 ms on the tick: the scoreboard pre-generates and the
-- first clients warm the cache)
create or replace function capb.world(r int) returns void language plpgsql as $$
begin
  perform mc.generate_batch('minecraft:overworld', array_agg(x), array_agg(z)) from generate_series(-r, r) x, generate_series(-r, r) z;
  perform mc.chunk_packet('minecraft:overworld', x, z) from generate_series(-r, r) x, generate_series(-r, r) z;
end $$;

-- the clients' input for one tick: k position packets per moving client (k = 1: the client keeps up with the server; k = 2: a tick of 100 ms), then keep-alive and teleport answers.
-- frac = the fraction of the clients that walk (the others only send client_tick_end, which the gateway does not pass on)
create or replace function capb.gen(p_frac float8 default 1.0, p_k int default 1, p_bound float8 default 780) returns void language plpgsql as $$
declare i_pos int := net.pkt('play', 'serverbound', 'minecraft:move_player_pos'); i_te int := net.pkt('play', 'serverbound', 'minecraft:client_tick_end');
        i_ka int := net.pkt('play', 'serverbound', 'minecraft:keep_alive'); i_tp int := net.pkt('play', 'serverbound', 'minecraft:accept_teleportation');
        cur bigint := (select game_time from mc.game_state); sp float8 := 4.317 / 20.0; j int;
begin
  update capb.walk w set heading = case when abs(p.x) > p_bound or abs(p.z) > p_bound then atan2(-p.z, -p.x) + (random() - 0.5) * 1.2 else random() * 2 * pi() end,
         turn_at = cur + (case when abs(p.x) > p_bound or abs(p.z) > p_bound then 40 + random() * 60 else 60 + random() * 100 end)::int
    from mc.player p where p.conn_id = w.conn_id and (w.turn_at <= cur or abs(p.x) > p_bound or abs(p.z) > p_bound);
  for j in 1 .. p_k loop
    insert into net.inbox (conn_id, payload)
    select p.conn_id, proto.varint(i_pos) || proto.f64(p.x + cos(w.heading) * sp * j) || proto.f64(p.y) || proto.f64(p.z + sin(w.heading) * sp * j) || '\x01'::bytea
      from mc.player p join capb.walk w on w.conn_id = p.conn_id
     where p.conn_id is not null and p.conn_id % 1000 < p_frac * 1000 and p.awaiting_teleport is null;
    if p_k >= 2 then
      insert into net.inbox (conn_id, payload) select p.conn_id, proto.varint(i_te) from mc.player p where p.conn_id is not null and p.conn_id % 1000 < p_frac * 1000;
    end if;
  end loop;
  insert into net.inbox (conn_id, payload)
  select conn_id, proto.varint(i_ka) || proto.i64(keepalive_id) from mc.player where conn_id is not null and keepalive_id is not null;
  insert into net.inbox (conn_id, payload)
  select conn_id, proto.varint(i_tp) || proto.varint(awaiting_teleport) || proto.f64(x) || proto.f64(y) || proto.f64(z) || proto.f32(yaw) || proto.f32(pitch)
    from mc.player where conn_id is not null and awaiting_teleport is not null;
end $$;
