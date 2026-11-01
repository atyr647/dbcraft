-- Parallel-safety marking of the functions the tick's read-only computations call.  proparallel: s = safe, r = restricted, u = unsafe (the default for user functions).
select n.nspname || '.' || p.proname as fn, p.proparallel as par, p.provolatile as vol, l.lanname as lang
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace join pg_language l on l.oid = p.prolang
 where n.nspname in ('mc', 'net', 'proto')
   and p.proname in ('quant', 'angle_byte', 'varint', 'i16', 'i32', 'bool', 'f64', 'f32', 'f64_read', 'f32_read', 'pkt_teleport_entity', 'frame', 'chunk_packet',
                     'pid', 'sid', 'varint_safe', 'varint_read', 'pkt_player_position', 'cb', 'pkt_move_entity_pos', 'entity_type_id', 'player_info_body')
 order by 1;
select proparallel, count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname in ('mc', 'net', 'proto') group by 1 order by 1;
