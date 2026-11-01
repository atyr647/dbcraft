\timing on
\set QUIET on
set jit=off;
create temp table pk as select i, decode(lpad(to_hex(((random()*2e6)::int)|8388736 & 16777215 | 8421504),6,'0'),'hex') b from generate_series(1,200000) i;
-- make valid 3-byte varints: bytes with continuation bits on first two
update pk set b = set_byte(set_byte(set_byte('\x000000'::bytea,0,128+(random()*127)::int),1,128+(random()*127)::int),2,(random()*100)::int);
create or replace function vdec(b bytea) returns int language plpgsql immutable as $$ declare i int:=0; r int:=0; s int:=0; c int; begin loop c:=get_byte(b,i); r:=r|((c&127)<<s); exit when (c&128)=0; s:=s+7; i:=i+1; end loop; return r; end $$;
create or replace function vdec_sql(b bytea) returns int language sql immutable as $$ select case when get_byte(b,0)<128 then get_byte(b,0) when get_byte(b,1)<128 then (get_byte(b,0)&127)|(get_byte(b,1)<<7) else (get_byte(b,0)&127)|((get_byte(b,1)&127)<<7)|(get_byte(b,2)<<14) end $$;
\echo == D: varint decode 200k DIFFERENT packets, plpgsql loop
select sum(vdec(b)) from pk;
\echo == E: same, inlined SQL expression
select sum(vdec_sql(b)) from pk;
\echo == E+JIT (jit_above_cost=0)
set jit=on; set jit_above_cost=0; set jit_inline_above_cost=0; set jit_optimize_above_cost=0;
select sum(vdec_sql(b)) from pk;
set jit=off;
\echo == F: pack 200 sections x 4096 entries x 5 bits (pure SQL)
create or replace function pack5(idx int[]) returns bytea language sql immutable as $$
 select decode(string_agg(lpad(to_hex(w),16,'0'),'' order by g),'hex') from (
   select i/12 g, bit_or(((idx[i+1])::bigint << ((i%12)*5))) w from generate_series(0,4095) i group by i/12) t $$;
create temp table secs as select s, array(select (random()*20)::int from generate_series(1,4096)) a from generate_series(1,200) s;
select sum(length(pack5(a))) from secs;
set jit=on; set jit_above_cost=0; set jit_inline_above_cost=0; set jit_optimize_above_cost=0;
\echo -- F with JIT forced on
select sum(length(pack5(a))) from secs;
set jit=off;
\echo == G: AES-ECB pgcrypto, 200k DIFFERENT blocks
create temp table blk as select i, decode(md5(i::text),'hex') d from generate_series(1,200000) i;
select count(encrypt(d,'0123456789abcdef'::bytea,'aes-ecb/pad:none')) from blk;
\echo == H: AES-CFB8 decrypt of 100 x 1KB messages, hand-built in plpgsql from ECB
create or replace function cfb8_dec(c bytea, key bytea, iv bytea) returns bytea language plpgsql as $$
declare sr bytea:=iv; o bytea:='\x'; i int; k int; cb int; n int:=length(c); out bytea:=repeat(E'\\000',n)::bytea;
begin for i in 0..n-1 loop
  k:=get_byte(encrypt(sr,key,'aes-ecb/pad:none'),0); cb:=get_byte(c,i);
  out:=set_byte(out,i,k#cb); sr:=substring(sr from 2)||set_byte('\x00'::bytea,0,cb);
 end loop; return out; end $$;
select sum(length(cfb8_dec(decode(repeat(md5(g::text),32),'hex'),'0123456789abcdef'::bytea,'\x00112233445566778899aabbccddeeff'::bytea))) from generate_series(1,100) g;
