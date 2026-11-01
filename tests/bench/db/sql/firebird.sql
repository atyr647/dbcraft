drop procedure loopmove
--;;
drop function vdec
--;;
drop table players
--;;
create table players(id int not null primary key, region int default 0 not null, x double precision, y double precision, z double precision, tick bigint)
--;;
drop table pk_varint
--;;
create table pk_varint(i int not null primary key, b varchar(3) character set octets)
--;;
drop table inbox
--;;
create table inbox(conn_id int, seq int, packet_id int, body varchar(33) character set octets)
--;;
create or alter procedure loopmove as declare variable i int; begin for select id from players into :i do update players set x=x+0.1 where id=:i; end
--;;
create or alter function vdec(b varchar(3) character set octets) returns integer as declare variable i int = 1; declare variable r int = 0; declare variable s int = 0; declare variable c int; begin while (1=1) do begin c = ascii_val(substring(b from :i for 1)); r = bin_or(:r, bin_shl(bin_and(:c,127), :s)); if (bin_and(:c,128)=0) then leave; s = s+7; i = i+1; end return r; end
--;;
create index players_region on players(region)
