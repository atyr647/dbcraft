-- Experiment: autovacuum parameters for the per-tick queue tables (insert N rows, delete them next tick).  The server-level naptime is a separate knob (conf/av_fast.conf).
do $$ declare t text; begin
  foreach t in array array['net.inbox','net.outbox','net.batch','net.play_inbox','mc.play_in','mc.play_in_work','mc.play_out','mc.pending_ack','mc.kick','mc.block_event','mc.block_actor','mc.visible'] loop
    if to_regclass(t) is not null then
      execute format('alter table %s set (autovacuum_vacuum_scale_factor = 0, autovacuum_vacuum_threshold = 2000, autovacuum_vacuum_cost_delay = 0, autovacuum_analyze_scale_factor = 0, autovacuum_analyze_threshold = 1000)', t);
    end if;
  end loop;
end $$;
