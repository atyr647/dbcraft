drop table if exists players
--;;
create table players(id integer primary key, region int not null default 0, x real, y real, z real, tick integer)
--;;
drop table if exists pk_varint
--;;
create table pk_varint(i integer primary key, b blob)
--;;
drop table if exists inbox
--;;
create table inbox(conn_id int, seq int, packet_id int, body blob)
--;;
create index players_region on players(region)
