-- sql/465: proto.mutf8 / nbt.mutf8 skip the regular expression for ASCII text.  Same bytes as the originals (copied below as t.*_ref) for every input.
\ir ../../sql/465_join_text.sql

create or replace function t.mutf8_ref(s text) returns bytea language plpgsql immutable parallel safe as $$
declare out bytea := '\x'; ch text; cp int; hi int; lo int;
begin
  if s !~ E'[\\U00010000-\\U0010FFFF\\u0000]' then return convert_to(s, 'UTF8'); end if;
  for ch in select regexp_split_to_table(s, '') loop
    cp := ascii(ch);
    if cp = 0 then out := out || '\xC080'::bytea;
    elsif cp >= 65536 then
      cp := cp - 65536; hi := 55296 + (cp >> 10); lo := 56320 + (cp & 1023);
      out := out || decode(to_hex(224 | (hi >> 12)) || to_hex(128 | ((hi >> 6) & 63)) || to_hex(128 | (hi & 63))
                        || to_hex(224 | (lo >> 12)) || to_hex(128 | ((lo >> 6) & 63)) || to_hex(128 | (lo & 63)), 'hex');
    else out := out || convert_to(ch, 'UTF8');
    end if;
  end loop;
  return out;
end $$;
create or replace function t.nbt_mutf8_ref(s text) returns bytea language plpgsql immutable as $$
declare out bytea := '\x'; ch text; cp int; x int; i int;
begin
    if s !~ '[\U00010000-\U0010FFFF]' then return convert_to(s, 'UTF8'); end if;
    for i in 1 .. char_length(s) loop
        ch := substr(s, i, 1); cp := ascii(ch);
        if cp > 65535 then
            cp := cp - 65536;
            foreach x in array array[55296 + (cp >> 10), 56320 + (cp & 1023)] loop
                out := out || set_byte(set_byte(set_byte('\x000000'::bytea, 0, 224 | (x >> 12)), 1, 128 | ((x >> 6) & 63)), 2, 128 | (x & 63));
            end loop;
        else out := out || convert_to(ch, 'UTF8'); end if;
    end loop;
    return out;
end $$;

select t.eq('plain ASCII', encode(proto.mutf8('with'), 'hex'), '77697468');
select t.eq('Latin-1 and CJK are ordinary UTF-8', encode(proto.mutf8('é日'), 'hex'), 'c3a9e697a5');
select t.eq('a supplementary character becomes two 3-byte surrogates (U+1F600)', encode(proto.mutf8('😀'), 'hex'), 'eda0bdedb880');
select t.eq('...in the middle of text', encode(proto.mutf8('a😀b'), 'hex'), '61eda0bdedb88062');
select t.eq('the empty string', proto.mutf8(''), '\x'::bytea);
select t.eq('NULL gives what the original gave (empty)', proto.mutf8(null), t.mutf8_ref(null));
select t.eq('nbt.mutf8: a supplementary character (U+1D11E)', encode(nbt.mutf8('𝄞'), 'hex'), encode(t.nbt_mutf8_ref('𝄞'), 'hex'));

-- random text from ASCII, Latin-1, CJK, symbols and supplementary characters, 0 to 15 characters (the length is a column: see tests/sql/460)
create table t.rnd_txt as
select s.id, (select coalesce(string_agg((array['a', 'Z', '0', ' ', '_', ':', 'é', 'ß', 'Ä', '日', '本', '✓', '€', '😀', '𝄞', '𐍈'])[1 + floor(random() * 16)::int], ''), '') from generate_series(1, s.n) k) as s
from (select g as id, floor(random() * 16)::int as n from generate_series(1, 30000) g) s;
select t.is_true('the random text has all kinds: ASCII only, non-ASCII BMP, supplementary',
  (select count(*) filter (where octet_length(s) = char_length(s)) > 1000 and count(*) filter (where octet_length(s) > char_length(s) and s !~ '[\U00010000-\U0010FFFF]') > 1000
          and count(*) filter (where s ~ '[\U00010000-\U0010FFFF]') > 1000 and count(distinct char_length(s)) >= 14 from t.rnd_txt));
select t.eq('proto.mutf8: 30,000 random strings equal the original', (select count(*)::int from t.rnd_txt where proto.mutf8(s) is distinct from t.mutf8_ref(s)), 0);
select t.eq('nbt.mutf8: 30,000 random strings equal the original', (select count(*)::int from t.rnd_txt where nbt.mutf8(s) is distinct from t.nbt_mutf8_ref(s)), 0);
select t.eq('the NBT string builders built on it are unchanged (proto.nbt_text, nbt.str)',
  (select count(*)::int from t.rnd_txt where proto.nbt_text(s) is distinct from proto.i16(octet_length(t.mutf8_ref(s))) || t.mutf8_ref(s)
                                           or nbt.str(s) is distinct from proto.i16(octet_length(t.nbt_mutf8_ref(s))) || t.nbt_mutf8_ref(s)), 0);
