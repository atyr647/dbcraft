-- mc.play_out.data: STORAGE EXTERNAL (out of line, never compressed).  The per-tick queue holds values of 10 KB and more in a crowd (a per-chunk blob of movement packets,
-- sql/430_tick_perf_fanout.sql); with the default EXTENDED every value is run through pglz when it is written, which cost 2,000 viewers x 11 KB about 450 ms per tick
-- (fan-out 614 ms -> 120-180 ms measured at 2,000 crowded walking players).  net.outbox.data has been EXTERNAL since the join-storm work; it is the same reason.
alter table mc.play_out alter column data set storage external;
