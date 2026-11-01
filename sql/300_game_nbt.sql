-- Game module, part 1: network NBT writers and text components.
-- Network NBT (26.x): the root tag is a nameless compound (type byte 0x0A, then fields, then 0x00).  Field order matters: vanilla writes
-- keys in its codec's order (e.g. with, color, translate), NOT sorted, so builders take fields explicitly in order.
-- A "fields" value is the concatenation of named tags; wrap it with proto.nbt_root(...) (root), proto.nbt_comp(name, ...) (named child),
-- or fields || '\x00' (an element of a list<compound>).

create or replace function proto.cat(parts bytea[]) returns bytea language sql immutable parallel safe as $$
  select coalesce((select string_agg(x, '\x'::bytea order by ord) from unnest(parts) with ordinality t(x, ord)), '\x'::bytea) $$;

-- Modified UTF-8 (what NBT strings use): like UTF-8 except U+0000 is C0 80 and supplementary characters are two 3-byte surrogates.
create or replace function proto.mutf8(s text) returns bytea language plpgsql immutable parallel safe as $$
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

-- u16 length + modified UTF-8: tag names and string payloads
create or replace function proto.nbt_text(s text) returns bytea language sql immutable parallel safe as $$
  select proto.i16(octet_length(m)) || m from (select proto.mutf8(s) m) q $$;

create or replace function proto.nbt_byte(name text, v int)     returns bytea language sql immutable parallel safe as $$ select '\x01'::bytea || proto.nbt_text(name) || proto.i8(v) $$;
create or replace function proto.nbt_short(name text, v int)    returns bytea language sql immutable parallel safe as $$ select '\x02'::bytea || proto.nbt_text(name) || proto.i16(v) $$;
create or replace function proto.nbt_int(name text, v int)      returns bytea language sql immutable parallel safe as $$ select '\x03'::bytea || proto.nbt_text(name) || proto.i32(v) $$;
create or replace function proto.nbt_long(name text, v bigint)  returns bytea language sql immutable parallel safe as $$ select '\x04'::bytea || proto.nbt_text(name) || proto.i64(v) $$;
create or replace function proto.nbt_float(name text, v real)   returns bytea language sql immutable parallel safe as $$ select '\x05'::bytea || proto.nbt_text(name) || proto.f32(v) $$;
create or replace function proto.nbt_double(name text, v float8) returns bytea language sql immutable parallel safe as $$ select '\x06'::bytea || proto.nbt_text(name) || proto.f64(v) $$;
create or replace function proto.nbt_str(name text, v text)     returns bytea language sql immutable parallel safe as $$ select '\x08'::bytea || proto.nbt_text(name) || proto.nbt_text(v) $$;
create or replace function proto.nbt_bool(name text, v boolean) returns bytea language sql immutable parallel safe as $$ select proto.nbt_byte(name, case when v then 1 else 0 end) $$;
create or replace function proto.nbt_int_array(name text, v int[]) returns bytea language sql immutable parallel safe as $$
  select '\x0b'::bytea || proto.nbt_text(name) || proto.i32(coalesce(array_length(v, 1), 0))
         || coalesce((select string_agg(proto.i32(x), '\x'::bytea order by ord) from unnest(v) with ordinality t(x, ord)), '\x'::bytea) $$;
create or replace function proto.nbt_list_str(name text, items text[]) returns bytea language sql immutable parallel safe as $$
  select '\x09'::bytea || proto.nbt_text(name) || '\x08'::bytea || proto.i32(coalesce(array_length(items, 1), 0))
         || coalesce((select string_agg(proto.nbt_text(x), '\x'::bytea order by ord) from unnest(items) with ordinality t(x, ord)), '\x'::bytea) $$;
-- items: each element is the fields of one compound (this function appends the 0x00 terminator)
create or replace function proto.nbt_list_comp(name text, items bytea[]) returns bytea language sql immutable parallel safe as $$
  select '\x09'::bytea || proto.nbt_text(name) || '\x0a'::bytea || proto.i32(coalesce(array_length(items, 1), 0))
         || coalesce((select string_agg(x || '\x00'::bytea, '\x'::bytea order by ord) from unnest(items) with ordinality t(x, ord)), '\x'::bytea) $$;
create or replace function proto.nbt_comp(name text, variadic fields bytea[]) returns bytea language sql immutable parallel safe as $$
  select '\x0a'::bytea || proto.nbt_text(name) || proto.cat(fields) || '\x00'::bytea $$;
create or replace function proto.nbt_root(variadic fields bytea[]) returns bytea language sql immutable parallel safe as $$
  select '\x0a'::bytea || proto.cat(fields) || '\x00'::bytea $$;

------------------------------------------------------------------------------------------------ text components
-- Each tc_* returns the FIELDS of a component compound.  NULL arguments are skipped (string_agg ignores NULL parts).

-- {with:[...], color:..., translate:key}.  args: fields of each argument compound (use tc_text / tc_translate / tc_player results).
create or replace function mc.tc_translate(key text, args bytea[] default null, color text default null) returns bytea language sql immutable parallel safe as $$
  select proto.cat(array[case when args is not null then proto.nbt_list_comp('with', args) end,
                         case when color is not null then proto.nbt_str('color', color) end,
                         proto.nbt_str('translate', key)]) $$;
-- args that are all plain strings use list<string> (vanilla's compact form, seen in commands.time.set.time_marker feedback)
create or replace function mc.tc_translate_strs(key text, args text[]) returns bytea language sql immutable parallel safe as $$
  select proto.cat(array[proto.nbt_list_str('with', args), proto.nbt_str('translate', key)]) $$;
create or replace function mc.tc_text(txt text, color text default null) returns bytea language sql immutable parallel safe as $$
  select proto.cat(array[case when color is not null then proto.nbt_str('color', color) end, proto.nbt_str('text', txt)]) $$;   -- vanilla order: color, then text

-- The clickable, hoverable player name used in join/leave/command messages (key order read from vanilla's bytes).
create or replace function mc.tc_player(p_uuid uuid, p_name text) returns bytea language sql immutable parallel safe as $$
  select proto.cat(array[
    proto.nbt_comp('click_event', proto.nbt_str('action', 'suggest_command'), proto.nbt_str('command', '/tell ' || p_name || ' ')),
    proto.nbt_str('insertion', p_name),
    proto.nbt_str('text', p_name),
    proto.nbt_comp('hover_event', proto.nbt_str('name', p_name), proto.nbt_str('action', 'show_entity'), proto.nbt_str('id', 'minecraft:player'),
                   proto.nbt_int_array('uuid', array[proto.i32_read(proto.uuid(p_uuid), 0), proto.i32_read(proto.uuid(p_uuid), 4),
                                                     proto.i32_read(proto.uuid(p_uuid), 8), proto.i32_read(proto.uuid(p_uuid), 12)]))]) $$;
