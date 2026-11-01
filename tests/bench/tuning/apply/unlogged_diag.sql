-- Experiment: diagnostics tables and the derived chunk cache as UNLOGGED (not WAL-logged; truncated by crash recovery).
alter table mc.tick_log set unlogged;
alter table mc.server_tick_log set unlogged;
alter table mc.error_log set unlogged;
alter table mc.chunk_cache set unlogged;
