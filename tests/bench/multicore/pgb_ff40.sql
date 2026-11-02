-- rewrite the first four private hot tables at fillfactor 40 (room for one complete replacement of every row inside the page: a full-table UPDATE cannot reuse the old
-- versions of its own statement, so 60 leaves 40% free for 100% new versions and a third of the rows go to other pages)
alter table w_0 set (fillfactor = 40);
alter table w_1 set (fillfactor = 40);
alter table w_2 set (fillfactor = 40);
alter table w_3 set (fillfactor = 40);
alter table wu_0 set (fillfactor = 40);
alter table wu_1 set (fillfactor = 40);
alter table wu_2 set (fillfactor = 40);
alter table wu_3 set (fillfactor = 40);
vacuum full w_0;
vacuum full w_1;
vacuum full w_2;
vacuum full w_3;
vacuum full wu_0;
vacuum full wu_1;
vacuum full wu_2;
vacuum full wu_3;
select pg_stat_reset();
