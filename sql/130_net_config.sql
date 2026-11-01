-- TEMPORARY STUB (replaced by the real configuration sequence).
create or replace function net.config_begin(p_conn bigint) returns void language sql as $$ select 1 $$;
create or replace function net.h_config(p_conn bigint, p_name text, body bytea) returns void language plpgsql as $$
begin raise exception 'unexpected configuration packet %', p_name; end $$;
create or replace function net.h_play(p_conn bigint, pid int, p_name text, body bytea) returns void language plpgsql as $$
begin raise exception 'unexpected play packet %', p_name; end $$;
create or replace function net.on_disconnect(p_conn bigint) returns void language sql as $$ delete from net.conn where conn_id = p_conn $$;
