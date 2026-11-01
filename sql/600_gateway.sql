-- The real gateway's side of the contract (gateway/, docs/GATEWAY.md): tables, control channel, statistics.  New objects only; nothing here changes the
-- offline path.  The gateway holds no state of its own that the database does not also hold in a row.
--
-- Control channel (DB -> gateway), polled once per tick after the drain:
--   net.gateway_ctl(after_seq)  rows of net.conn whose compression threshold, protocol state or key-exchange flag changed since the gateway last asked
--     compression  the threshold now in effect (-1 off): the gateway inflates INBOUND frames of that connection from now on (outbound framing is the DB's)
--     state        'play' lifts the small pre-login frame limit
--     await_key    online mode: SQL sent encryption_request; the gateway takes the NEXT inbound frame as the key response, decrypts it (RSA), switches the
--                  socket to AES-128-CFB8 in both directions, asks Mojang and reports the verdict into net.auth_result
--     name, verify_token   what the gateway needs for that (the requested user name; the 4-byte challenge SQL generated)
-- Gateway -> DB, inside the tick's transaction: COPY net.inbox, net.auth_begun(ids), insert into net.auth_result, net.apply_auth_results().

------------------------------------------------------------------------------------------------ columns on net.conn
alter table net.conn add column if not exists await_key     boolean not null default false;   -- encryption_request sent, key response not yet seen
alter table net.conn add column if not exists auth_pending  boolean not null default false;   -- key accepted, session check running in the gateway
alter table net.conn add column if not exists verify_token  bytea;
-- The "something changed" stamp is NOT a column of net.conn: it comes from a sequence, so a column would make otherwise identical rows differ between runs, and
-- the differential tests compare whole rows (md5 of to_jsonb(net.conn)).  It lives in a side table kept by triggers.
drop trigger if exists ctl_stamp on net.conn;                   -- an earlier revision stamped the row itself
alter table net.conn drop column if exists ctl_seq;

create sequence if not exists net.ctl_seq;
create unlogged table if not exists net.conn_ctl (conn_id bigint primary key, ctl_seq bigint not null);
create or replace function net.ctl_stamp() returns trigger language plpgsql as $$
begin
    if tg_op = 'DELETE' then
        delete from net.conn_ctl where conn_id = old.conn_id;
        return old;
    end if;
    insert into net.conn_ctl (conn_id, ctl_seq) values (new.conn_id, nextval('net.ctl_seq')) on conflict (conn_id) do update set ctl_seq = excluded.ctl_seq;
    return new;
end $$;
-- fires only when something the gateway has to act on changes (state, threshold, key exchange), so the per-tick keep-alive updates of net.conn stay in-place (HOT) updates
create trigger ctl_stamp after insert or update of state, compression, await_key on net.conn for each row execute function net.ctl_stamp();
drop trigger if exists ctl_stamp_delete on net.conn;
create trigger ctl_stamp_delete after delete on net.conn for each row execute function net.ctl_stamp();
insert into net.conn_ctl (conn_id, ctl_seq) select conn_id, nextval('net.ctl_seq') from net.conn on conflict (conn_id) do nothing;     -- rows that exist when this file is applied

create or replace function net.gateway_ctl(p_after bigint default 0)
returns table (conn_id bigint, ctl_seq bigint, state text, compression int, await_key boolean, name text, verify_token bytea)
language sql stable as $$
    select c.conn_id, k.ctl_seq, c.state, c.compression, c.await_key, c.name, case when c.await_key then c.verify_token end
    from net.conn c join net.conn_ctl k on k.conn_id = c.conn_id where k.ctl_seq > p_after order by k.ctl_seq $$;

------------------------------------------------------------------------------------------------ gateway start
-- A gateway process numbers its connections from 1.  The rows of the previous process describe sockets that died with it, and anything still queued for those ids
-- would be delivered to the NEW connections that reuse them.  So a gateway calls this once, first thing: every stale connection is disconnected through the normal path
-- (net.on_disconnect: the game saves and removes the player, tells the others) and the queues that could still carry bytes for old ids are emptied.
-- Returns the number of stale connections that were cleaned.
create or replace function net.gateway_start() returns int language plpgsql as $$
declare r record; n int := 0;
begin
    for r in select conn_id from net.conn order by conn_id loop
        begin
            perform net.on_disconnect(r.conn_id);
        exception when others then
            delete from net.conn where conn_id = r.conn_id;               -- a failing hook must not keep a dead row alive
        end;
        n := n + 1;
    end loop;
    delete from net.inbox; delete from net.batch; delete from net.play_inbox; delete from net.outbox; delete from net.auth_result;
    if to_regclass('mc.play_out') is not null then execute 'delete from mc.play_out'; end if;     -- the game's queue (sql/360) feeds net.outbox at the end of the tick
    return n;
end $$;

------------------------------------------------------------------------------------------------ online mode: keys and verdicts
-- The gateway publishes its RSA public key (X.509 SubjectPublicKeyInfo DER, 1024 bit like vanilla) once at start.
create table if not exists net.server_key (id int primary key check (id = 1), public_der bytea not null, updated_at timestamptz not null default now());

-- The gateway's verdicts: written inside the tick's transaction, applied by net.apply_auth_results() before the game tick.
--   ok = true:  uuid, name and properties come from Mojang's hasJoined answer ([{"name","value","signature"?}, ...])
--   ok = false: reason is 'invalid' (no/invalid session: multiplayer.disconnect.unverified_username) or 'unavailable' (multiplayer.disconnect.authservers_down)
create unlogged table if not exists net.auth_result (seq bigint generated always as identity primary key, conn_id bigint not null, ok boolean not null,
                                                     reason text, uuid uuid, name text, properties jsonb not null default '[]');

create or replace function net.auth_begun(p_conns bigint[]) returns int language sql as $$
    with u as (update net.conn set await_key = false, auth_pending = true where conn_id = any(p_conns) and await_key returning 1) select count(*)::int from u $$;

------------------------------------------------------------------------------------------------ profile properties (skins)
-- Readable rows; the wire form (VarInt count, then name, value, nullable signature: 26.3's GAME_PROFILE_PROPERTIES codec, count at most 16) is built on demand.
create table if not exists mc.player_property (uuid uuid not null, ord int not null, name text not null, value text not null, signature text, primary key (uuid, ord));

create or replace function mc.profile_props(p_uuid uuid) returns bytea language sql stable parallel safe as $$
    select coalesce((select proto.varint(count(*)::int)
                            || string_agg(proto.string(p.name) || proto.string(p.value)
                                          || case when p.signature is null then '\x00'::bytea else '\x01'::bytea || proto.string(p.signature) end, '\x'::bytea order by p.ord)
                     from mc.player_property p where p.uuid = p_uuid having count(*) > 0), '\x00'::bytea) $$;

------------------------------------------------------------------------------------------------ statistics
-- One row per second, written by the gateway (and trimmed by it to the last hour).
create table if not exists net.gateway_stats (ts timestamptz primary key default now(), ticks int not null, late_ticks int not null, tick_ms_avg float8, tick_ms_max float8,
                                              db_ms_avg float8, frames_in bigint not null, bytes_in bigint not null, frames_out bigint not null, bytes_out bigint not null,
                                              connections int not null, rejected int not null default 0, errors int not null default 0);
