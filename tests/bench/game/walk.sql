-- directional walkers: each bot walks along its heading by `sp` blocks per tick and turns around at the edge of the area (side x side chunks)
create or replace function bench.gen_walk(sp float8, side float8) returns void language plpgsql as $$
begin
  insert into mc.play_in (conn_id, packet_id, body)
  select conn_id, mc.sid('move_player_pos_rot'),
         proto.f64(nx) || proto.f64(y) || proto.f64(nz) || proto.f32(nyaw::real) || proto.f32(pitch) || '\x01'::bytea
    from (select conn_id, y, pitch,
                 case when out then yaw + 180 else yaw end as nyaw,
                 case when out then x else x - sin(radians(yaw)) * sp end as nx,
                 case when out then z else z + cos(radians(yaw)) * sp end as nz
            from (select p.*, (x - sin(radians(yaw)) * sp < 4 or x - sin(radians(yaw)) * sp > side * 16 - 4 or z + cos(radians(yaw)) * sp < 4 or z + cos(radians(yaw)) * sp > side * 16 - 4) as out
                    from mc.player p where conn_id is not null) q) w;
  insert into mc.play_in (conn_id, packet_id, body) select conn_id, mc.sid('client_tick_end'), '\x'::bytea from mc.player where conn_id is not null;
end $$;
