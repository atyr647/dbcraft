-- Experiment: no pglz attempt for payload columns that hold packets (queues and the chunk cache).  Existing cache rows are rewritten so the new mode applies.
alter table net.outbox alter column data set storage external;
alter table mc.play_out alter column data set storage external;
alter table net.inbox alter column payload set storage external;
alter table mc.play_in alter column body set storage external;
alter table mc.chunk_cache alter column packet set storage external;
update mc.chunk_cache set packet = packet || ''::bytea;
vacuum mc.chunk_cache;
