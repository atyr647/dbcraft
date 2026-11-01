-- Harness for the sharded movement prototype (sql/434): one pgbench client = one shard worker.  Run on a database that has the integrated schema, sql/434 and
-- a populated world (tests/bench/tick/parallel/shard_run.sh builds it with ibench.setup(PLAYERS, 100) and mc.refresh_visibility()).
create schema if not exists par2;
create sequence if not exists par2.tick_seq;
-- one tick of shard k of n: the movement packets of the shard's connections (the gateway's job), the sharded movement, and the discard of the output
-- queued for the shard's connections (the drain)
create or replace function par2.iter(p_k int, p_n int) returns int language plpgsql as $$
declare cur bigint := nextval('par2.tick_seq'); i_pr int := mc.sid('move_player_pos_rot'); i_te int := mc.sid('client_tick_end'); r record;
begin
  insert into mc.play_in_work (conn_id, packet_id, body)
  select conn_id, i_pr, proto.f64(x + (random() - 0.5) * 0.4) || proto.f64(y) || proto.f64(z + (random() - 0.5) * 0.4) || proto.f32((yaw + 1)::real) || proto.f32(pitch) || '\x01'::bytea
    from mc.player where conn_id is not null and conn_id % p_n = p_k;
  insert into mc.play_in_work (conn_id, packet_id, body) select conn_id, i_te, '\x'::bytea from mc.player where conn_id is not null and conn_id % p_n = p_k;
  select * into r from mc.apply_player_moves_shard(cur, p_k, p_n);
  delete from mc.play_out where conn_id % p_n = p_k;
  return r.moved;
end $$;
