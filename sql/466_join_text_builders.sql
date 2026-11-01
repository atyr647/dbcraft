-- Login-path speed, round 7: the NBT / text component builders stop being re-planned on every call.
--
-- Measured (docs/PERF-JOIN.md): building the join message (compound { with: [player component], translate }) took 2.0-2.3 ms although every piece is cheap.  The builders are
-- `language sql` functions that Postgres cannot inline: proto.nbt_text and nbt.str have a FROM clause (select ... from (select mutf8(s)) q), proto.cat / nbt_int_array /
-- nbt_list_str / nbt_list_comp contain a sub-select with unnest + string_agg.  A function that is not inlined is planned again on every call from PL/pgSQL, 100-300 us
-- each, and one message makes dozens of them.
--   * nbt_text / nbt.str: one expression, so they inline (and so do the nbt_* writers and tc_* builders that call them);
--   * cat / nbt_int_array / nbt_list_str / nbt_list_comp: PL/pgSQL loops (plan cached for the session; a few microseconds per call).
-- NULL behaviour is the original's: NULL elements of a bytea / int array are skipped (string_agg ignores NULL parts), a NULL text item is the empty string, a NULL array is empty,
-- and the length written is the array's element count.
-- Same bytes for every input (tests/sql/466_join_text_builders.sql compares them with the originals on random input).

-- u16 length + modified UTF-8 (the payload of a TAG_String and of every tag name)
create or replace function proto.nbt_text(s text) returns bytea language sql immutable parallel safe as $$
  select proto.i16(octet_length(proto.mutf8(s))) || proto.mutf8(s) $$;
create or replace function nbt.str(s text) returns bytea language sql immutable as $$
    select proto.i16(octet_length(nbt.mutf8(s))) || nbt.mutf8(s) $$;

-- concatenation of the non-NULL elements, in order
create or replace function proto.cat(parts bytea[]) returns bytea language plpgsql immutable parallel safe as $$
declare out bytea := '\x'; x bytea;
begin
    if parts is null then return out; end if;
    foreach x in array parts loop
        if x is not null then out := out || x; end if;
    end loop;
    return out;
end $$;

create or replace function proto.nbt_int_array(name text, v int[]) returns bytea language plpgsql immutable parallel safe as $$
declare out bytea; x int;
begin
    out := '\x0b'::bytea || proto.nbt_text(name) || proto.i32(coalesce(array_length(v, 1), 0));
    if v is not null then
        foreach x in array v loop
            if x is not null then out := out || proto.i32(x); end if;
        end loop;
    end if;
    return out;
end $$;

create or replace function proto.nbt_list_str(name text, items text[]) returns bytea language plpgsql immutable parallel safe as $$
declare out bytea; x text;
begin
    out := '\x09'::bytea || proto.nbt_text(name) || '\x08'::bytea || proto.i32(coalesce(array_length(items, 1), 0));
    if items is not null then
        foreach x in array items loop
            out := out || proto.nbt_text(x);                              -- a NULL item is the empty string here, as in the original (mutf8(NULL) is empty, so nbt_text(NULL) = 00 00)
        end loop;
    end if;
    return out;
end $$;

-- items: each element is the fields of one compound (this function appends the 0x00 terminator)
create or replace function proto.nbt_list_comp(name text, items bytea[]) returns bytea language plpgsql immutable parallel safe as $$
declare out bytea; x bytea;
begin
    out := '\x09'::bytea || proto.nbt_text(name) || '\x0a'::bytea || proto.i32(coalesce(array_length(items, 1), 0));
    if items is not null then
        foreach x in array items loop
            if x is not null then out := out || x || '\x00'::bytea; end if;
        end loop;
    end if;
    return out;
end $$;
