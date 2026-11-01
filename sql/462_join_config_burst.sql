-- Login-path speed, round 3: the configuration burst as ONE cached, fully framed value.
--
-- Before: for every joiner, net.send_config_data inserted 33 rows into net.outbox (32 registry_data packets + update_tags, about 216 KB), framing each packet
-- for that connection's compression threshold on the spot (with a threshold, each of them ran through deflate again, for every joiner).  Measured 3.6 ms per joiner,
-- of which about 2.2 ms was Postgres trying to pglz-compress each large outbox row.
-- Now: the framed packets are concatenated once per (known-packs variant, compression threshold, deflate implementation) into net.config_burst and a joiner gets
-- that one value in one row.  The drain concatenates a connection's rows in order, so the bytes on the wire are exactly the same.
--
-- net.config_burst is a CACHE: unlogged, rebuilt on first use, emptied whenever net.config_cache changes (which the existing triggers on ref.dp_* already do),
-- and keyed by the deflate implementation (so switching mc.select_deflate() never serves frames made by the other one).

-- Rows of net.outbox are written once and read once: compressing them costs CPU and buys nothing (the gateway needs the bytes).
alter table net.outbox alter column data set storage external;

create unlogged table if not exists net.config_burst (
    variant   text  not null,           -- known packs that matter (net.known_variant)
    threshold int   not null,           -- the connection's compression threshold (-1 = off)
    impl      text  not null,           -- md5 of the active mc.deflate_zlib body (implementation and level)
    burst     bytea not null,           -- the framed configuration packets, in order (finish_configuration is NOT part of it: net.h_config sends it)
    primary key (variant, threshold, impl)
);
alter table net.config_burst alter column burst set storage external;

create or replace function net.invalidate_config_burst() returns trigger language plpgsql as $$
begin delete from net.config_burst; return null; end $$;
drop trigger if exists invalidate_config_burst on net.config_cache;
create trigger invalidate_config_burst after insert or update or delete on net.config_cache for each statement execute function net.invalidate_config_burst();
drop trigger if exists invalidate_config_burst_truncate on net.config_cache;
create trigger invalidate_config_burst_truncate after truncate on net.config_cache for each statement execute function net.invalidate_config_burst();   -- TRUNCATE does not fire the DELETE trigger

-- Same contract as sql/140_registry.sql: queue the configuration packets for a connection, building the cache first if needed.
create or replace function net.send_config_data(p_conn bigint, p_known text[]) returns void language plpgsql as $$
declare v text := net.known_variant(p_known); thr int; v_impl text; b bytea;
begin
    select compression into thr from net.conn where conn_id = p_conn;
    if thr is null then return; end if;                                            -- the connection is gone: nothing to send (the original inserted no rows either)
    v_impl := coalesce((select md5(prosrc) from pg_proc where oid = 'mc.deflate_zlib(bytea)'::regprocedure), '');
    select burst into b from net.config_burst where variant = v and threshold = thr and impl = v_impl;
    if b is null then
        if not exists (select 1 from net.config_cache where variant = v) then perform net.config_cache_build(v); end if;
        select string_agg(net.frame(thr, pk.protocol_id, k.body), ''::bytea order by k.seq) into b
          from net.config_cache k
          join ref.packet pk on pk.state = 'configuration' and pk.direction = 'clientbound' and pk.name = k.packet
         where k.variant = v;
        if b is null then return; end if;                                          -- no registry rows loaded: nothing to send (and nothing to cache)
        insert into net.config_burst (variant, threshold, impl, burst) values (v, thr, v_impl, b) on conflict do nothing;
    end if;
    insert into net.outbox (conn_id, data) values (p_conn, b);
end $$;
