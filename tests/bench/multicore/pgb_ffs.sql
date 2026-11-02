-- the shared hot table at fillfactor 40 as well (see pgb_ff40.sql)
alter table w_s set (fillfactor = 40);
vacuum full w_s;
select pg_stat_reset();
