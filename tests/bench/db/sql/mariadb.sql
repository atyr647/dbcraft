drop table if exists players
--;;
create table players(id int primary key, region int not null default 0, x double, y double, z double, tick bigint) engine=InnoDB
--;;
drop table if exists pk_varint
--;;
create table pk_varint(i int primary key, b varbinary(3)) engine=InnoDB
--;;
drop table if exists inbox
--;;
create table inbox(conn_id int, seq int, packet_id int, body varbinary(33)) engine=InnoDB
--;;
drop procedure if exists loopmove
--;;
create procedure loopmove() begin declare i int default 1; while i<=10000 do update players set x=x+0.1 where id=i; set i=i+1; end while; end
--;;
drop function if exists vdec
--;;
create function vdec(b varbinary(3)) returns int deterministic begin declare i int default 1; declare r int default 0; declare s int default 0; declare c int; lp: loop set c=ord(substr(b,i,1)); set r=r|((c&127)<<s); if (c&128)=0 then leave lp; end if; set s=s+7; set i=i+1; end loop; return r; end
--;;
create index players_region on players(region)
