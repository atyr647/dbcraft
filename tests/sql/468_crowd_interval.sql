-- Vanilla's update interval for players (EntityType.PLAYER.updateInterval(2), read from the bytecode: docs/PERF-CROWD.md): a walking player's position reaches its viewers
-- every second tick as ONE packet carrying ticks = 2 and the combined delta, not every tick.  The phase is per entity: (tick + entity id) % interval = 0.
create or replace function t.walk_setup(p_interval int) returns void language plpgsql as $$
begin
  truncate mc.play_out, mc.play_in, mc.play_in_work, mc.visible, mc.kick; delete from mc.player;
  update mc.server_property set value = '10' where key = 'view-distance';
  update mc.server_property set value = p_interval::text where key = 'dbcraft.player-update-interval';
  insert into mc.player (uuid, name, conn_id, entity_id, x, y, z, yaw, pitch, on_ground, chunk_x, chunk_z, sent_qx, sent_qy, sent_qz, sent_yaw, sent_pitch, vis_dirty, last_sent_tick)
  select md5(i::text)::uuid, 'w' || i, i, 100 + i, 0.5, 64, 0.5, 0, 0, true, 0, 0, mc.quant(0.5), mc.quant(64), mc.quant(0.5), 0, 0, true, 0 from generate_series(1, 2) i;
  perform count(*) from mc.refresh_visibility();
  truncate mc.play_out;
end $$;
-- player 1 (conn 1, entity 101) walks 0.215 blocks per tick along x; player 2 watches.  Returns the ticks at which player 2 received a packet about player 1
create or replace function t.walk_ticks(p_ticks int, p_start bigint) returns table(tick bigint, nbytes int, data bytea, x float8) language plpgsql as $$
declare i int; cur bigint; px float8 := 0.5;
begin
  for i in 1 .. p_ticks loop
    cur := p_start + i; px := px + 0.215;
    insert into mc.play_in_work (conn_id, seq, packet_id, body)
    values (1, 1, mc.sid('move_player_pos'), proto.f64(px) || proto.f64(64) || proto.f64(0.5) || '\x01'::bytea);
    perform mc.apply_player_moves(cur);
    tick := cur; x := px; data := (select string_agg(o.data, '\x'::bytea order by o.seq) from mc.play_out o where o.conn_id = 2); nbytes := coalesce(octet_length(data), 0);
    delete from mc.play_out;
    return next;
  end loop;
end $$;

select t.walk_setup(2);
create temp table w2 as select * from t.walk_ticks(20, 100);
select t.eq('interval 2: exactly half of the ticks carry a packet (10 of 20)', (select count(*) from w2 where nbytes > 0)::int, 10);
select t.is_true('interval 2: they are every second tick', (select bool_and(tick % 2 = (select min(tick) from w2 where nbytes > 0) % 2) from w2 where nbytes > 0));
select t.is_true('interval 2: and none in between', (select not bool_or(tick % 2 <> (select min(tick) from w2 where nbytes > 0) % 2) from w2 where nbytes > 0));

-- the packets: the first move after joining has ticks = 2 (the interval), NOT the number of game ticks since the join (that was 6317 in a live probe, so a real client
-- would interpolate the other player over five minutes: vanilla's first packet is ticks = 2, delta one tick); then ticks = 2 and the delta of two ticks.
select t.walk_setup(2);
create temp table w4 as select * from t.walk_ticks(12, 5000);
select t.is_true('interval 2: the first packet carries ticks = 2 and the one-tick delta, however late in the game it is (tick 5000)', (
  select data = mc.pkt_move_entity_pos(101, (mc.quant(x) - mc.quant(0.5))::int, 0, 0, 2, true) from w4 where nbytes > 0 order by tick limit 1));
select t.is_true('interval 2: every later packet is move_entity_pos with ticks = 2 and the delta of two ticks (11 bytes)', (
  select bool_and(data = mc.pkt_move_entity_pos(101, (mc.quant(x) - mc.quant(lx))::int, 0, 0, 2, true) and nbytes = 11)
    from (select *, lag(x, 2) over (order by tick) as lx from w4) q
   where nbytes > 0 and lx is not null and tick > (select min(tick) from w4 where nbytes > 0)));
select t.eq('interval 2: those packets exist (5 later ones in 12 ticks)', (select count(*) from w4 where nbytes > 0)::int, 6);

-- interval 1 restores the old every-tick behaviour
select t.walk_setup(1);
create temp table w1 as select * from t.walk_ticks(20, 100);
select t.eq('interval 1: every tick carries a packet', (select count(*) from w1 where nbytes > 0)::int, 20);

-- a player that stands still sends nothing, whatever the phase
select t.walk_setup(2);
select t.eq('standing still: no packet in 10 ticks', (select count(*) from (
  select mc.apply_player_moves(100 + g) from generate_series(1, 10) g) q where false)::int, 0);

-- the first move after joining goes out within one tick (it is not delayed by a whole interval): a player that has never sent anything
select t.walk_setup(2);
create temp table w3 as select * from t.walk_ticks(2, 200);
select t.eq('the first move is sent within one tick (interval 2)', (select count(*) from w3 where nbytes > 0)::int, 1);
