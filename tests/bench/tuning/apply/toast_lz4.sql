-- Experiment: lz4 instead of pglz for the same columns (much cheaper to compress and decompress; slightly larger output).
alter table net.outbox alter column data set compression lz4;
alter table mc.play_out alter column data set compression lz4;
alter table net.inbox alter column payload set compression lz4;
alter table mc.play_in alter column body set compression lz4;
alter table mc.chunk_cache alter column packet set compression lz4;
update mc.chunk_cache set packet = packet || ''::bytea;
vacuum mc.chunk_cache;
