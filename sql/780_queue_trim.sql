-- Queue hygiene that does not depend on autovacuum.  See docs/SOAK.md.
--
-- The per-tick queues net.inbox and net.outbox (and mc.play_in) are filled and emptied with DELETE ... RETURNING every tick.  Dead rows are only reclaimed by a vacuum.
-- sql/435 left these three to autovacuum because the gateway shares them with the tick, which therefore cannot truncate them blindly.  That assumption fails twice:
--   * the PL/Python development gateway is ONE long CALL: a backend only reports its table statistics when it goes idle, so autovacuum never sees a dead row;
--   * autovacuum_naptime defaults to one minute, and a login burst alone (200 joiners at view distance 10 = about 1 GB of chunk and configuration bytes) leaves
--     a heap that every later tick has to scan: the DELETE of net.drain_outbox() reads EVERY page, live or not.  Measured with 200 walking players: the heap
--     only grows, the drain gets slower every minute, and after about four minutes the loop misses a whole keep-alive round and every client is kicked.
--
-- The fix is local and needs no vacuum: right after the drain (the one moment the queues are empty because the same transaction consumed them), a queue whose
-- total size (heap + TOAST + indexes) exceeds a bound is TRUNCATEd.  A truncate gives the space back at once and, unlike an aggressive vacuum, leaves no
-- "reltuples = 0" statistic that would make the planner believe the table has one row (sql/435).  Cost: one new relation file per truncate, and the cached plans
-- that mention the table are rebuilt once; with the default bound that happens every few seconds under load and never when the queues stay small.
--   dbcraft.queue-trim-bytes   (mc.server_property)   bound in bytes, default 8 MiB; 0 disables the trimming
--
-- Safe with ONE gateway session (the design today): only that session writes the queues.  With several gateway processes sharing one database this must be
-- disabled (dbcraft.queue-trim-bytes = 0) and the queues vacuumed instead (tools/janitor.sh, or the gateway's maintenance connection).

insert into mc.server_property (key, value, default_value, note)
values ('dbcraft.queue-trim-bytes', '8388608', '8388608', 'dbcraft: net.drain_outbox() truncates net.inbox/net.outbox when they are bigger than this many bytes (heap + TOAST) and empty; 0 = never (docs/SOAK.md)')
on conflict (key) do nothing;

create unlogged table if not exists net.queue_trim_stat (
    rel        regclass primary key,
    trims      bigint not null default 0,
    last_bytes bigint not null default 0,          -- the size at the last truncate
    max_bytes  bigint not null default 0,          -- the largest size ever truncated
    last_at    timestamptz
) with (fillfactor = 70);

-- Truncates p_rel when it is bigger than p_limit bytes AND empty.  Returns true when it did.  Never waits for a lock and never loses a row.
create or replace function net.trim_queue(p_rel regclass, p_limit bigint) returns boolean language plpgsql volatile as $$
declare sz bigint; has boolean;
begin
    sz := pg_total_relation_size(p_rel);
    if sz <= p_limit then return false; end if;
    begin
        execute format('lock table %s in access exclusive mode nowait', p_rel);          -- another session is using it: try again next tick
    exception when lock_not_available then return false;
    end;
    execute format('select exists (select 1 from %s)', p_rel) into has;                  -- a row that is still waiting must survive
    if has then return false; end if;
    execute format('truncate %s', p_rel);
    insert into net.queue_trim_stat (rel, trims, last_bytes, max_bytes, last_at) values (p_rel, 1, sz, sz, now())
    on conflict (rel) do update set trims = net.queue_trim_stat.trims + 1, last_bytes = sz, max_bytes = greatest(net.queue_trim_stat.max_bytes, sz), last_at = now();
    return true;
end $$;

create or replace function net.trim_queues() returns int language plpgsql volatile as $$
declare lim bigint := coalesce(nullif(mc.prop('dbcraft.queue-trim-bytes'), '')::bigint, 8388608); n int := 0;
begin
    if lim <= 0 then return 0; end if;
    if net.trim_queue('net.outbox', lim) then n := n + 1; end if;
    if net.trim_queue('net.inbox', lim) then n := n + 1; end if;
    if net.trim_queue('mc.play_in', lim) then n := n + 1; end if;                              -- filled and consumed inside one tick: empty here too
    return n;
end $$;

-- What the gateway asks for each tick (sql/100): all pending bytes per connection, in order, and whether to close afterwards.  Unchanged except for the last line.
create or replace function net.drain_outbox() returns table(conn_id bigint, data bytea, close boolean) language plpgsql as $$
begin
    -- sql/800: nothing to hand over (an idle server): no statement but the probe; the queues' size check, which this tick's rows cannot have changed, runs once a second
    if not exists (select 1 from net.outbox) and not exists (select 1 from net.conn where closing) then
        if (select game_time from mc.game_state) % 20 = 0 then perform net.trim_queues(); end if;
        return;
    end if;
    return query
    with out as (delete from net.outbox returning net.outbox.conn_id, net.outbox.seq, net.outbox.data),
         agg as (select o.conn_id, string_agg(o.data, ''::bytea order by o.seq) as data from out o group by o.conn_id),
         cl  as (select c.conn_id from net.conn c where c.closing)
    select coalesce(a.conn_id, cl.conn_id), coalesce(a.data, '\x'::bytea), (cl.conn_id is not null)
    from agg a full join cl on cl.conn_id = a.conn_id;
    delete from net.conn where closing;
    perform net.trim_queues();                                                                -- queue hygiene without autovacuum (sql/780, docs/SOAK.md)
end $$;
