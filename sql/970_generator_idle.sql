-- Idle cost, part 3 (docs/PERF-IDLE2.md): a chunk generator that costs nothing while there is nothing to generate.
--
--   mc.run_generator_until_idle(p_batch, p_poll_ms, p_exit_idle_ms)
--       The loop of mc.run_generator (sql/430_chunk_queue.sql) with one difference: it RETURNS after p_exit_idle_ms without a chunk request instead of polling for ever.
--       The Rust gateway runs it in threads of its own (settings `generators`, gateway/src/generators.rs) and starts it again when the tick's probe (net.gateway_pending, bit 4)
--       reports a row in mc.chunk_request, so a parked generator costs no wake-ups at all: the two polling loops used 0.0065 cores of an empty server's 0.018.
--       While there is work it behaves exactly like mc.run_generator: generate_pending(p_batch), commit, poll every p_poll_ms when a pass found nothing.
--       Stops early when mc.generator_control.stop is set, like the other loop.  Safe to run from any number of connections (generate_pending skips locked rows).
--
-- The request queue is also part of the quiet predicate (sql/800: a pending request makes the tick not quiet) so that net.gateway_pending's bit 4 is never hidden by the quiet shortcut.

create or replace procedure mc.run_generator_until_idle(p_batch int default 64, p_poll_ms int default 5, p_exit_idle_ms int default 1500) language plpgsql as $$
declare n int; idle_since timestamptz;
begin
    loop
        n := 0;
        if exists (select 1 from mc.chunk_request) then n := mc.generate_pending(p_batch); end if;
        commit;
        exit when (select stop from mc.generator_control);
        if n = 0 then
            if idle_since is null then idle_since := clock_timestamp(); end if;
            exit when clock_timestamp() - idle_since >= make_interval(secs => p_exit_idle_ms / 1000.0);
            perform pg_sleep(p_poll_ms / 1000.0);
            commit;
        else
            idle_since := null;
        end if;
    end loop;
end $$;
