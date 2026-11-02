-- Join budget: smooth login storms without changing a byte any client receives.  Measurements and the trade-off curve: docs/PERF-JOINBUDGET.md.
--
-- THE PROBLEM.  Joining a player costs about 28 ms of database time (login checks, configuration burst, mc.on_join, entry burst, chunk batch).  A storm of 200 joins
-- in one second made one tick of 5.7 s (docs/SCOREBOARD.md): the packets pile up while the tick runs, so the next tick is bigger still.  Vanilla's ticks stay near 50 ms
-- because its logins are authenticated off the main thread and chunks stream slowly.  Everybody already online froze for seconds.
--
-- THE FIX: an admission gate in front of the login.  A connection's `hello` (login start) is the first packet of real work.  net.join_gate() runs at the start of
-- every tick's input phase (net.process_fast, net.process, mc.ingest_batched call it) and
--   1. parks the hello packets that arrived this tick in net.join_parked (they keep their net.inbox sequence number),
--   2. releases the parked packets of the OLDEST `rate` logins back into net.inbox, in arrival order, so the normal handlers process them in this same tick.
-- Everything after the hello (configuration, entry burst, chunks) flows exactly as before, so a joiner receives the same bytes; only WHEN it joins changes.
-- With few simultaneous joins the rate is never reached and nothing is delayed.
--
-- THE RATE is adaptive (AIMD, like TCP): it starts at dbcraft.join-initial-rate; while there is a backlog it grows by 1 per tick as long as the PREVIOUS tick took no longer
-- than (the tick length before the storm + dbcraft.join-budget-ms) (mc.server_tick_log), and halves when the previous tick took longer.  Never below 1 (nobody starves).  A DEADLINE FLOOR guarantees that
-- no login waits (much) longer than dbcraft.join-max-wait-s of REAL time: rate >= backlog / (ticks left until the oldest parked login is due; a tick counts as long as it took).  A parked client sits in the login protocol
-- state, where the server cannot send it anything (a keep-alive is not a legal login packet), so the wait must stay under the client's 30 s read timeout and
-- vanilla's own limit (ServerLoginPacketListenerImpl.MAX_TICKS_BEFORE_LOGIN = 600 ticks): the default is 20 s.  Once a client is released it is never delayed again.
--
-- The gate itself is cheap: nothing to do (no connection in handshake/login state and nothing parked) costs one index-free scan of the small net.conn table.

insert into mc.server_property (key, value, default_value, note) values
    ('dbcraft.join-budget-ms',    '25', '25', 'dbcraft: login storms: while logins are queued, admit more of them per tick only while the previous tick took at most (the tick length before the storm + this many ms); off = admit every login at once (the old behaviour)'),
    ('dbcraft.join-max-wait-s',   '20', '20', 'dbcraft: login storms: no login waits (much) longer than this many seconds in the queue; must stay well under the clients'' 30 s timeout and vanilla''s own limit of 600 login ticks'),
    ('dbcraft.join-initial-rate', '3',  '3',  'dbcraft: login storms: logins admitted in the first tick of a storm (a burst up to this size is not delayed at all)')
on conflict (key) do nothing;

-- Parked login packets.  A cache of "work not yet admitted": unlogged, emptied by a crash (the connections are gone then too).
create unlogged table if not exists net.join_parked (
    seq         bigint primary key,           -- the net.inbox sequence number: release order is arrival order
    conn_id     bigint not null,
    payload     bytea  not null,
    parked_ms   bigint not null               -- wall-clock ms (net.join_now_ms) when it was parked: waits are measured in REAL time, because a slow tick must not stretch them
);
create index if not exists join_parked_conn_idx on net.join_parked (conn_id);

-- One row of controller state and counters (HOT updates: fillfactor).
create unlogged table if not exists net.join_gate_state (
    id             int primary key default 1 check (id = 1),
    rate           double precision not null default 3,
    active         boolean not null default false,     -- there was a backlog at the previous call
    base_ms        double precision,                   -- the tick length just before the storm began: the budget is headroom over it
    parked_total   bigint not null default 0,
    released_total bigint not null default 0,
    forced_total   bigint not null default 0,          -- calls where the deadline floor, not the AIMD rate, decided
    max_queue      int not null default 0,
    last_release   int not null default 0
) with (fillfactor = 50);
insert into net.join_gate_state (id) values (1) on conflict do nothing;

-- The clock the gate uses, in ms.  The real clock, unless a session sets dbcraft.sim_clock_ms (the storm simulation in tests/bench/joinbudget does, to run ticks
-- faster or slower than real time).
create or replace function net.join_now_ms() returns bigint language sql volatile as $$
    select coalesce(nullif(current_setting('dbcraft.sim_clock_ms', true), '')::bigint, (extract(epoch from clock_timestamp()) * 1000)::bigint) $$;

-- The intent (1 status, 2 login, 3 transfer) of an intention packet, null when it does not parse.
create or replace function net.handshake_intent(p_payload bytea) returns int language plpgsql immutable as $$
declare o int := net.pid_len(p_payload);
begin
    o := (proto.varint_read(p_payload, o)).nxt;            -- protocol version
    o := (proto.string_read(p_payload, o)).nxt;            -- server address
    return (proto.varint_read(p_payload, o + 2)).val;      -- (+2: port) intent
exception when others then
    return null;
end $$;

create or replace function net.join_gate() returns int language plpgsql volatile as $$
declare
    b text := coalesce(mc.prop('dbcraft.join-budget-ms'), '25');
    budget real; w_s real; r0 real; hello int; cur bigint; q int; n int; np int := 0; st net.join_gate_state; last_ms real;
    new_rate double precision; age_ms bigint; ticks_left float8; floor_r int; rr int; now_ms bigint;
begin
    if lower(b) in ('off', '0', '-1', '') then
        -- budget off (possibly switched off while logins were parked): release everything, the old behaviour exactly
        if exists (select 1 from net.join_parked) then
            insert into net.inbox (conn_id, seq, payload) select conn_id, seq, payload from net.join_parked;
            delete from net.join_parked;
            update net.join_gate_state set active = false;
        end if;
        return 0;
    end if;
    if not exists (select 1 from net.join_parked)
       and not exists (select 1 from net.conn where state in ('handshake', 'login') limit 1) then
        -- nothing that could be a login; the storm (if there was one) is over: the next one starts from the initial rate
        update net.join_gate_state set active = false, rate = coalesce(mc.prop('dbcraft.join-initial-rate'), '3')::double precision, last_release = 0 where id = 1 and active;
        return 0;
    end if;
    budget := b::real;
    -- capped at 25 s: a parked client sends nothing, and the gateway drops a connection that sent no bytes for 30 s (gateway read_timeout_s), vanilla's own login limit is 30 s
    w_s := least(25, coalesce(mc.prop('dbcraft.join-max-wait-s'), '20')::real);
    r0 := coalesce(mc.prop('dbcraft.join-initial-rate'), '3')::real;
    hello := net.pkt('login', 'serverbound', 'minecraft:hello');
    now_ms := net.join_now_ms();

    -- 1a. a connection still in the handshake state whose first packet is an intention packet for login (or transfer): everything it sent after it is parked
    --     (a client sends the handshake and the hello back to back; the status ping, intent 1, is never delayed)
    with first_pkt as (
            select distinct on (i.conn_id) i.conn_id, i.seq, i.payload
              from net.inbox i join net.conn c on c.conn_id = i.conn_id and c.state = 'handshake'
             order by i.conn_id, i.seq),
         login_conns as (select conn_id, seq from first_pkt where net.handshake_intent(payload) in (2, 3)),
         moved as (delete from net.inbox i using login_conns l where i.conn_id = l.conn_id and i.seq > l.seq returning i.conn_id, i.seq, i.payload)
    insert into net.join_parked (seq, conn_id, payload, parked_ms) select seq, conn_id, payload, now_ms from moved;
    get diagnostics n = row_count; np := np + n;
    -- 1b. the hello of a connection already in the login state
    with moved as (delete from net.inbox i using net.conn c
                    where c.conn_id = i.conn_id and c.state = 'login' and net.pid(i.payload) = hello
                returning i.conn_id, i.seq, i.payload)
    insert into net.join_parked (seq, conn_id, payload, parked_ms) select seq, conn_id, payload, now_ms from moved;
    get diagnostics n = row_count; np := np + n;
    -- connections that closed while parked
    delete from net.join_parked p where not exists (select 1 from net.conn c where c.conn_id = p.conn_id);

    select * into st from net.join_gate_state;
    select count(distinct conn_id)::int into q from net.join_parked;      -- the unit is a LOGIN (connection), not a packet
    if q = 0 then
        if st.active then update net.join_gate_state set active = false, rate = r0, last_release = 0 where id = 1; end if;
        return 0;
    end if;

    -- 2. how many may go now
    last_ms := (select l.ms_total from mc.server_tick_log l order by l.tick desc limit 1);
    if not st.active then
        new_rate := r0;                                                             -- the first tick of a storm
        st.base_ms := coalesce(last_ms, 0);                                         -- the tick before it is the baseline the budget is measured against
    elsif coalesce(last_ms, 0) > st.base_ms + budget then new_rate := greatest(1, st.rate * 0.5);    -- the last tick was too long: back off (never below 1 per tick)
    else new_rate := least(st.rate + 1, 1000);                                       -- room left: admit one more per tick
    end if;
    -- the deadline floor: the oldest parked login is due w_s seconds after it was parked; the ticks left until then are (time left) / (a tick's length: the previous
    -- one, at least 50 ms and at most 250 ms).  ceil() makes it at least 1 per tick while anything is parked: nobody starves.  Counting nominal 50 ms ticks instead
    -- looked safer but is not: slow ticks then leave far fewer ticks than counted, the floor stays low and the whole backlog is admitted in a burst just before the
    -- deadline (measured: 22 logins in each of the last ticks, 500-700 ms ticks).
    age_ms := greatest(0, now_ms - (select min(parked_ms) from net.join_parked));
    ticks_left := greatest(1, (w_s * 1000 - age_ms) / least(250, greatest(50, coalesce(last_ms, 50))));
    floor_r := ceil(q::float8 / ticks_left)::int;
    rr := greatest(floor(new_rate)::int, floor_r);
    with sel as (select conn_id from net.join_parked group by conn_id order by min(seq) limit rr),          -- the oldest rr logins, all their parked packets
         rel as (delete from net.join_parked p using sel where p.conn_id = sel.conn_id returning p.conn_id, p.seq, p.payload)
    insert into net.inbox (conn_id, seq, payload) select conn_id, seq, payload from rel;
    get diagnostics n = row_count;
    update net.join_gate_state
       set rate = new_rate, active = true, base_ms = st.base_ms, parked_total = parked_total + np, released_total = released_total + n,
           forced_total = forced_total + case when floor_r > floor(new_rate) then 1 else 0 end,
           max_queue = greatest(max_queue, q), last_release = n
     where id = 1;
    return n;
end $$;
