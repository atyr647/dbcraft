-- Login-path speed, round 6: Java "modified UTF-8" for tag names and strings, the hot spot of building any text component.
--
-- Measured (docs/PERF-JOIN.md): the join message (a translatable text component: compound { with: [player component], translate }) takes 2.0 ms to build, 428 calls of
-- proto.mutf8 at about 4.6 us each: a PL/pgSQL function that runs a regular expression on every string, even on plain ASCII tag names such as "with" or "click_event".
-- A PostgreSQL text value cannot contain U+0000 and an ASCII-only string has octet_length = char_length, so for ASCII there is nothing special to look for: the answer is
-- the string's bytes.  The original bodies stay as *_general for everything else.  The wrappers are plain SQL, so the planner inlines them into the NBT builders.
-- Same bytes for every input, including NULL and the empty string (tests/sql/465_join_text.sql compares them with the originals on random text).

create or replace function proto.mutf8_general(s text) returns bytea language plpgsql immutable parallel safe as $$
declare out bytea := '\x'; ch text; cp int; hi int; lo int;
begin
  if s !~ E'[\\U00010000-\\U0010FFFF\\u0000]' then return convert_to(s, 'UTF8'); end if;   -- fast path: nothing special
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

create or replace function proto.mutf8(s text) returns bytea language sql immutable parallel safe as $$
  select case when octet_length(s) = char_length(s) then convert_to(s, 'UTF8') else proto.mutf8_general(s) end $$;

create or replace function nbt.mutf8_general(s text) returns bytea language plpgsql immutable as $$
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

create or replace function nbt.mutf8(s text) returns bytea language sql immutable as $$
    select case when octet_length(s) = char_length(s) then convert_to(s, 'UTF8') else nbt.mutf8_general(s) end $$;
