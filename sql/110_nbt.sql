-- NBT in network form (1.20.2+): the root tag has a type byte but NO name.  Text components travel as NBT too:
--   literal text       -> a bare TAG_String                      (08 | u16 length | modified UTF-8)
--   translatable text  -> compound { "with": list<string>, "translate": string }  (order as vanilla sends it)
create schema if not exists nbt;
comment on schema nbt is 'Network NBT writers. Registry data is encoded from rows by nbt.encode_entry (sql/140_registry.sql).';

-- Java "modified UTF-8": like UTF-8 but supplementary characters are two 3-byte surrogates and U+0000 is C0 80.
create or replace function nbt.mutf8(s text) returns bytea language plpgsql immutable as $$
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

-- u16 length + modified UTF-8: the payload of a TAG_String and of every tag name.
create or replace function nbt.str(s text) returns bytea language sql immutable as $$
    select proto.i16(octet_length(m)) || m from (select nbt.mutf8(s) as m) q $$;

create or replace function nbt.text_literal(s text) returns bytea language sql immutable as $$
    select '\x08'::bytea || nbt.str(s) $$;

create or replace function nbt.text_translate(key text, args text[] default '{}') returns bytea language sql immutable as $$
    select '\x0a'::bytea
        || case when coalesce(array_length(args, 1), 0) > 0
                then '\x09'::bytea || nbt.str('with') || '\x08'::bytea || proto.i32(array_length(args, 1))
                     || (select string_agg(nbt.str(a), ''::bytea order by o) from unnest(args) with ordinality t(a, o))
                else '\x'::bytea end
        || '\x08'::bytea || nbt.str('translate') || nbt.str(key)
        || '\x00'::bytea $$;

-- The same translatable component as JSON text, used in the login and status states.
create or replace function nbt.json_translate(key text, args text[] default '{}') returns text language sql immutable as $$
    select '{"translate":' || to_json(key)::text
        || case when coalesce(array_length(args, 1), 0) > 0
                then ',"with":[' || (select string_agg(to_json(a)::text, ',' order by o) from unnest(args) with ordinality t(a, o)) || ']'
                else '' end || '}' $$;
