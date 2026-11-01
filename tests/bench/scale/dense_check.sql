-- Are the replicas of the dense series valid?  The patched cached packet must equal the packet the server builds from the replica's rows.
\set ON_ERROR_STOP on
select count(*) as chunks, count(distinct (cx, cz)) as distinct_coords from mc.chunk where dimension = 'minecraft:overworld';
create temp table cached as select cx, cz, packet from mc.chunk_cache where dimension = 'minecraft:overworld';
select count(*) as cached_packets, round(avg(length(packet)) / 1024.0, 1) as avg_kib from cached;
select count(*) as identical_to_rebuild, count(*) filter (where mc.chunk_packet_build('minecraft:overworld', c.cx, c.cz) <> c.packet) as different
  from cached c where c.cx between 0 and 7 and c.cz between 0 and 7;
select count(*) as coords_inside_packet_match from cached c where proto.i32_read(mc.packet_body(c.packet), 0) = c.cx and proto.i32_read(mc.packet_body(c.packet), 4) = c.cz;
