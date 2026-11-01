-- PostgreSQL objects. Statements separated by lines containing only --
drop table if exists players
--;;
create table players(id int primary key, region int not null default 0, x float8, y float8, z float8, tick bigint) with (fillfactor=@FF@);
--;;
drop table if exists pk_varint;
--;;
create table pk_varint(i int primary key, b bytea);
--;;
drop table if exists inbox;
--;;
create unlogged table inbox(conn_id int, seq int, packet_id int, body bytea);
--;;
create or replace function loopmove() returns void language plpgsql as $$ declare r record; begin for r in select id from players loop update players set x=x+0.1 where id=r.id; end loop; end $$;
--;;
create or replace function vdec(b bytea) returns int language plpgsql immutable as $$ declare i int:=0; r int:=0; s int:=0; c int; begin loop c:=get_byte(b,i); r:=r|((c&127)<<s); exit when (c&128)=0; s:=s+7; i:=i+1; end loop; return r; end $$;
--;;
create index players_region on players(region)
