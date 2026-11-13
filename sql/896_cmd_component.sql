-- The `component` command argument (JSON / SNBT text components) and the commands that use it: /tellraw, /title (title, subtitle, actionbar, times, clear, reset)
-- (docs/MINING-AND-COMMANDS.md).  In 26.3 a component argument is SNBT: strings in " or ', unquoted words, numbers with type suffixes, true / false (a byte), lists [a, b], compounds
-- {key: value} with quoted or unquoted keys, trailing commas allowed -- so every JSON text component is one.  The value is then decoded with the component codec and sent
-- re-encoded: a literal with no style and no siblings is a bare string tag, a list is its first component with the others as `extra`, and a compound's keys come out in Java HashMap
-- order (the order of `java.util.HashMap<String, Tag>`: bucket (h ^ h >>> 16) & (capacity - 1), insertion order inside a bucket; recorded from the real server: tests/e2e/cmd_blocks.py,
-- group title).
--
-- Supported component forms: text, translate (+ fallback, with), keybind, selector (resolved to the names of the players it selects, as the commands do), score and nbt (resolved to an
-- empty literal: there are no scoreboards or data), style color (names and #rrggbb), bold italic underlined strikethrough obfuscated (booleans or numbers), shadow_color (int or four
-- floats), insertion, font, click_event {action ...}, hover_event {action ...} with show_text / show_item / show_entity passed through as given, and extra.  The error text of the codec
-- (`argument.component.invalid` with the DataResult message) is reproduced for the cases recorded (a number, a boolean, a compound without content, an empty list, a bad colour, a
-- non-numeric flag) and said to be unsupported for the others.  A syntax error that Mojang's SNBT parser reports with its own message is `argument.literal.incorrect` here when the
-- text ends early; other syntax errors are reported with the same key at the offending character.

-- Java's HashMap iteration order of the given keys (inserted in array order): bucket first, insertion order inside a bucket.  16 buckets up to 12 entries, then doubling.
create or replace function mc.java_hash_order(p_keys text[]) returns text[] language sql immutable as $$
  select coalesce(array_agg(k order by ((h # ((h >> 16) & 65535)) & (cap - 1)), o), '{}')
    from (select k, o, mc.java_string_hash(k) as h, case when cardinality(p_keys) <= 12 then 16 when cardinality(p_keys) <= 24 then 32 when cardinality(p_keys) <= 48 then 64 else 128 end as cap
            from unnest(p_keys) with ordinality t(k, o)) q $$;

------------------------------------------------------------------------------------------------ SNBT -> typed JSON
-- val: a string is a JSON string; a number {"$": "b|s|i|l|f|d", "v": n}; a list a JSON array; a compound a JSON object.  Booleans are bytes {"$": "b", "v": 1}.
create or replace function mc.snbt_value(s text, cur int) returns mc.cmd_ap language plpgsql immutable as $$
declare p int := mc.rd_skip_ws(s, cur); n int := length(s); c text; r mc.cmd_ap; items jsonb; key text; v jsonb; tok text; e int; m text[];
begin
  if p >= n then return mc.ap_err('argument.literal.incorrect', jsonb_build_array('"'), p); end if;
  c := substr(s, p + 1, 1);
  if c in ('"', '''') then
    r := mc.rd_string(s, p); if r.ex_key is not null then return r; end if;
    return mc.ap_ok(r.pos, r.val);
  elsif c = '{' then
    items := '{}'; p := mc.rd_skip_ws(s, p + 1);
    while true loop
      if p >= n then return mc.ap_err('argument.literal.incorrect', jsonb_build_array('"'), p); end if;
      if substr(s, p + 1, 1) = '}' then return mc.ap_ok(p + 1, items); end if;
      if substr(s, p + 1, 1) in ('"', '''') then r := mc.rd_string(s, p); if r.ex_key is not null then return r; end if; key := r.val #>> '{}'; p := r.pos;
      else e := mc.rd_unquoted_end(s, p); if e = p then return mc.ap_err('argument.literal.incorrect', jsonb_build_array('"'), p); end if; key := substr(s, p + 1, e - p); p := e; end if;
      p := mc.rd_skip_ws(s, p);
      if substr(s, p + 1, 1) <> ':' then return mc.ap_err('argument.literal.incorrect', jsonb_build_array(':'), p); end if;
      r := mc.snbt_value(s, p + 1); if r.ex_key is not null then return r; end if;
      items := items || jsonb_build_object(key, r.val); p := mc.rd_skip_ws(s, r.pos);
      if substr(s, p + 1, 1) = ',' then p := mc.rd_skip_ws(s, p + 1); continue; end if;
      if substr(s, p + 1, 1) = '}' then return mc.ap_ok(p + 1, items); end if;
      return mc.ap_err('argument.literal.incorrect', jsonb_build_array('}'), p);
    end loop;
  elsif c = '[' then
    items := '[]'; p := mc.rd_skip_ws(s, p + 1);
    while true loop
      if p >= n then return mc.ap_err('argument.literal.incorrect', jsonb_build_array('"'), p); end if;
      if substr(s, p + 1, 1) = ']' then return mc.ap_ok(p + 1, items); end if;
      r := mc.snbt_value(s, p); if r.ex_key is not null then return r; end if;
      items := items || jsonb_build_array(r.val); p := mc.rd_skip_ws(s, r.pos);
      if substr(s, p + 1, 1) = ',' then p := mc.rd_skip_ws(s, p + 1); continue; end if;
      if substr(s, p + 1, 1) = ']' then return mc.ap_ok(p + 1, items); end if;
      return mc.ap_err('argument.literal.incorrect', jsonb_build_array(']'), p);
    end loop;
  end if;
  -- an unquoted word: true / false, a number with an optional type suffix, else a string
  e := mc.rd_unquoted_end(s, p); tok := substr(s, p + 1, e - p);
  if tok = '' then return mc.ap_err('argument.literal.incorrect', jsonb_build_array('"'), p); end if;
  if tok = 'true' then return mc.ap_ok(e, jsonb_build_object('$', 'b', 'v', 1)); elsif tok = 'false' then return mc.ap_ok(e, jsonb_build_object('$', 'b', 'v', 0)); end if;
  m := regexp_match(tok, '^([+-]?[0-9]+)([bBsSlL]?)$');
  if m is not null then return mc.ap_ok(e, jsonb_build_object('$', case lower(m[2]) when 'b' then 'b' when 's' then 's' when 'l' then 'l' else 'i' end, 'v', m[1]::numeric)); end if;
  m := regexp_match(tok, '^([+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?)([fFdD]?)$');
  if m is not null and (m[4] <> '' or m[1] ~ '[.eE]') then return mc.ap_ok(e, jsonb_build_object('$', case lower(m[4]) when 'f' then 'f' else 'd' end, 'v', m[1]::numeric)); end if;
  return mc.ap_ok(e, to_jsonb(tok));
end $$;

-- SNBT's own text for a value (what Java's Tag.toString prints in the codec's error messages): strings in double quotes, byte 1b, int 5, float 5.0f, double 5.0d? (an int prints bare)
create or replace function mc.snbt_text(v jsonb) returns text language plpgsql immutable as $$
declare k text; parts text[] := '{}'; keys text[]; x jsonb;
begin
  case jsonb_typeof(v)
    when 'string' then return '"' || replace(replace(v #>> '{}', '\', '\\'), '"', '\"') || '"';
    when 'array' then return '[' || coalesce((select string_agg(mc.snbt_text(e), ',' order by o) from jsonb_array_elements(v) with ordinality t(e, o)), '') || ']';
    when 'object' then
      if v ? '$' then
        return (v ->> 'v') || case v ->> '$' when 'b' then 'b' when 's' then 's' when 'l' then 'L' when 'f' then 'f' when 'd' then 'd' else '' end;
      end if;
      keys := mc.java_hash_order(array(select jsonb_object_keys(v)));
      foreach k in array keys loop
        x := v -> k; parts := parts || (case when k ~ '^[A-Za-z0-9_.+-]+$' then k else mc.snbt_text(to_jsonb(k)) end || ':' || mc.snbt_text(x));
      end loop;
      return '{' || array_to_string(parts, ',') || '}';
    else return v #>> '{}';
  end case;
end $$;

------------------------------------------------------------------------------------------------ component codec
-- the tag of an NBT value as (type id, payload): used for the elements of lists
create or replace function mc.comp_tag(v jsonb, out t int, out payload bytea) language plpgsql immutable as $$
begin
  if jsonb_typeof(v) = 'string' then t := 8; payload := proto.nbt_text(v #>> '{}');
  elsif jsonb_typeof(v) = 'object' and v ? '$' then
    case v ->> '$'
      when 'b' then t := 1; payload := set_byte('\x00'::bytea, 0, ((v ->> 'v')::int) & 255);
      when 's' then t := 2; payload := proto.i16((v ->> 'v')::int);
      when 'i' then t := 3; payload := proto.i32((v ->> 'v')::int);
      when 'l' then t := 4; payload := proto.i64((v ->> 'v')::bigint);
      when 'f' then t := 5; payload := proto.f32((v ->> 'v')::real);
      else t := 6; payload := proto.f64((v ->> 'v')::float8);
    end case;
  else raise exception 'component: not a scalar'; end if;
end $$;

-- a list of tags: all of one type is a list of that type, anything else a list of compounds in which a non-compound is {"": value} (ListTag's wrapping)
create or replace function mc.comp_list(items jsonb[], itypes int[], ipay bytea[]) returns bytea language plpgsql immutable as $$
declare n int := coalesce(cardinality(items), 0); i int; same boolean := true; out bytea;
begin
  if n = 0 then return '\x00'::bytea || proto.i32(0); end if;
  for i in 2 .. n loop if itypes[i] <> itypes[1] then same := false; end if; end loop;
  if same then
    return set_byte('\x00'::bytea, 0, itypes[1]) || proto.i32(n) || (select string_agg(x, '\x'::bytea order by o) from unnest(ipay) with ordinality t(x, o));
  end if;
  return '\x0a'::bytea || proto.i32(n) || (select string_agg(case when itypes[o] = 10 then ipay[o] else set_byte('\x00'::bytea, 0, itypes[o]) || proto.nbt_text('') || ipay[o] || '\x00'::bytea end, '\x00'::bytea order by o)
                                           from generate_series(1, n) o) ;
end $$;

-- one NBT field: type, name, payload
create or replace function mc.comp_field(p_name text, p_type int, p_payload bytea) returns bytea language sql immutable as $$
  select set_byte('\x00'::bytea, 0, p_type) || proto.nbt_text(p_name) || p_payload $$;

-- a compound payload from fields given as (name, type, payload) in insertion order: written in HashMap order, closed with TAG_End
create or replace function mc.comp_compound(p_names text[], p_types int[], p_pays bytea[]) returns bytea language plpgsql immutable as $$
declare ord text[] := mc.java_hash_order(p_names); k text; i int; out bytea := '\x'::bytea;
begin
  foreach k in array ord loop i := array_position(p_names, k); out := out || mc.comp_field(k, p_types[i], p_pays[i]); end loop;
  return out || '\x00'::bytea;
end $$;

-- ChatFormatting colour names
create or replace function mc.comp_color_ok(c text) returns boolean language sql immutable as $$
  select c ~ '^#[0-9a-fA-F]{6}$' or c in ('black', 'dark_blue', 'dark_green', 'dark_aqua', 'dark_red', 'dark_purple', 'gold', 'gray', 'dark_gray', 'blue', 'green', 'aqua', 'red', 'light_purple', 'yellow', 'white') $$;

-- the codec's failure text for a value that is not a component at all
create or replace function mc.comp_err_text(v jsonb, why text default null) returns text language plpgsql immutable as $$
begin
  if why is not null then return why; end if;
  if jsonb_typeof(v) = 'array' and jsonb_array_length(v) = 0 then return 'Failed to parse either. First: Failed to parse either. First: Not a string; Second: List must have contents; Second: Not a map: []'; end if;
  return 'Failed to parse either. First: Failed to parse either. First: Not a string; Second: Not a list: ' || mc.snbt_text(v) || '; Second: ' ||
         case when jsonb_typeof(v) = 'object' and not v ? '$' then 'No matching codec found' else 'Not a map: ' || mc.snbt_text(v) end;
end $$;

-- Decode and re-encode one component (a string, a compound, or -- at the top level and inside `extra` -- a list).  Returns (type, payload).  p_me / p_target resolve selectors.
-- Raises 'component:<message>' for a value the codec refuses.
create or replace function mc.comp_enc(v jsonb, p_me mc.player, p_depth int default 0, out t int, out payload bytea) language plpgsql stable as $$
declare names text[] := '{}'; types int[] := '{}'; pays bytea[] := '{}'; k text; x jsonb; ex jsonb[] := '{}'; et int[] := '{}'; ep bytea[] := '{}'; r record; first_ record; wi jsonb[]; wt int[]; wp bytea[];
        has_content boolean := false; txt text; sel text; ap mc.cmd_ap; ps mc.player[]; selfields bytea; i int; sub record; flag int; hv jsonb; keys text[]; kk text;
begin
  if p_depth > 32 then raise exception 'component:Component is nested too deeply'; end if;
  if jsonb_typeof(v) = 'string' then t := 8; payload := proto.nbt_text(v #>> '{}'); return; end if;
  if jsonb_typeof(v) = 'array' then
    if jsonb_array_length(v) = 0 then raise exception 'component:%', mc.comp_err_text(v); end if;
    -- a list: the first component, the rest appended to its extra
    select * into first_ from mc.comp_enc(v -> 0, p_me, p_depth + 1);
    if jsonb_array_length(v) = 1 then t := first_.t; payload := first_.payload; return; end if;
    -- re-decode the first as a compound to append: build the extra list from its own extra plus the rest
    select ca.t, ca.payload into t, payload from mc.comp_append(v -> 0, (select jsonb_agg(e) from jsonb_array_elements(v) with ordinality q(e, o) where o > 1), p_me, p_depth) ca;
    return;
  end if;
  if jsonb_typeof(v) <> 'object' or v ? '$' then raise exception 'component:%', mc.comp_err_text(v); end if;
  -- content
  if v ? 'text' then
    if jsonb_typeof(v -> 'text') <> 'string' then raise exception 'component:%', mc.comp_err_text(v); end if;
    has_content := true; names := names || 'text'::text; types := types || 8; pays := pays || proto.nbt_text(v ->> 'text');
  elsif v ? 'translate' then
    if jsonb_typeof(v -> 'translate') <> 'string' then raise exception 'component:%', mc.comp_err_text(v); end if;
    has_content := true; names := names || 'translate'::text; types := types || 8; pays := pays || proto.nbt_text(v ->> 'translate');
    if v ? 'fallback' then names := names || 'fallback'::text; types := types || 8; pays := pays || proto.nbt_text(v ->> 'fallback'); end if;
    if v ? 'with' then
      wi := '{}'; wt := '{}'; wp := '{}';
      for x in select * from jsonb_array_elements(case when jsonb_typeof(v -> 'with') = 'array' then v -> 'with' else jsonb_build_array(v -> 'with') end) loop
        if jsonb_typeof(x) = 'object' and x ? '$' then select * into sub from mc.comp_tag(x);                       -- a number or flag in `with` stays that tag
        else select * into sub from mc.comp_enc(x, p_me, p_depth + 1); end if;
        wi := wi || x; wt := wt || sub.t; wp := wp || sub.payload;
      end loop;
      names := names || 'with'::text; types := types || 9; pays := pays || mc.comp_list(wi, wt, wp);
    end if;
  elsif v ? 'keybind' then
    has_content := true; names := names || 'keybind'::text; types := types || 8; pays := pays || proto.nbt_text(v ->> 'keybind');
  elsif v ? 'selector' then
    -- the names of the players it selects (ComponentUtils.updateForEntity); an empty selection is an empty literal
    has_content := true; sel := v ->> 'selector'; ap := mc.sel_parse(sel, 0, true);
    if ap.ex_key is not null then raise exception 'component:Invalid selector: %', sel; end if;
    ps := mc.sel_array(ap.val, p_me);
    if cardinality(ps) = 0 then names := names || 'text'::text; types := types || 8; pays := pays || proto.nbt_text('');
    elsif cardinality(ps) = 1 then
      -- the player's name component: its own fields take the place of the content
      selfields := mc.tc_player(ps[1].uuid, ps[1].name);
      t := 10; payload := selfields || '\x00'::bytea; return;
    else
      t := 10; payload := mc.sel_names_fields(ps) || '\x00'::bytea; return;
    end if;
  elsif v ? 'score' or v ? 'nbt' then
    has_content := true; names := names || 'text'::text; types := types || 8; pays := pays || proto.nbt_text('');                 -- no scoreboards, no data: resolved to nothing
  end if;
  if not has_content then raise exception 'component:%', mc.comp_err_text(v); end if;
  -- style, in the order of Style's codec
  if v ? 'color' then
    if jsonb_typeof(v -> 'color') <> 'string' or not mc.comp_color_ok(lower(v ->> 'color')) and not (v ->> 'color') ~ '^#[0-9a-fA-F]{6}$' then raise exception 'component:Invalid color name: %', v ->> 'color'; end if;
    names := names || 'color'::text; types := types || 8; pays := pays || proto.nbt_text(case when (v ->> 'color') ~ '^#' then upper(v ->> 'color') else v ->> 'color' end);
  end if;
  if v ? 'shadow_color' then
    x := v -> 'shadow_color';
    if jsonb_typeof(x) = 'array' and jsonb_array_length(x) = 4 then
      names := names || 'shadow_color'::text; types := types || 3;
      pays := pays || proto.i32((((floor(least(greatest((x #>> '{3,v}')::float8, 0), 1) * 255)::int) << 24) | ((floor(least(greatest((x #>> '{0,v}')::float8, 0), 1) * 255)::int) << 16)
                              | ((floor(least(greatest((x #>> '{1,v}')::float8, 0), 1) * 255)::int) << 8) | (floor(least(greatest((x #>> '{2,v}')::float8, 0), 1) * 255)::int))::int);
    elsif jsonb_typeof(x) = 'object' and x ? '$' and x ->> '$' in ('b', 's', 'i', 'l') then names := names || 'shadow_color'::text; types := types || 3; pays := pays || proto.i32((x ->> 'v')::bigint::int);
    else raise exception 'component:Not a number'; end if;
  end if;
  foreach k in array array['bold', 'italic', 'underlined', 'strikethrough', 'obfuscated'] loop
    if v ? k then
      x := v -> k;
      if jsonb_typeof(x) = 'object' and x ? '$' then flag := case when (x ->> 'v')::numeric <> 0 then 1 else 0 end;
      else raise exception 'component:Not a number'; end if;
      names := names || k; types := types || 1; pays := pays || set_byte('\x00'::bytea, 0, flag);
    end if;
  end loop;
  foreach k in array array['click_event', 'hover_event'] loop
    if v ? k then
      x := v -> k;
      if jsonb_typeof(x) <> 'object' then raise exception 'component:Not a map: %', mc.snbt_text(x); end if;
      keys := array(select jsonb_object_keys(x)); wi := '{}';
      declare cn text[] := '{}'; ct int[] := '{}'; cp bytea[] := '{}'; kx text; xv jsonb; sub2 record;
      begin
        foreach kx in array keys loop
          xv := x -> kx;
          if k = 'hover_event' and kx = 'value' and (x ->> 'action') = 'show_text' then
            select * into sub2 from mc.comp_enc(xv, p_me, p_depth + 1); cn := cn || kx; ct := ct || sub2.t; cp := cp || sub2.payload;
          elsif jsonb_typeof(xv) = 'object' and xv ? '$' then select * into sub2 from mc.comp_tag(xv); cn := cn || kx; ct := ct || sub2.t; cp := cp || sub2.payload;
          elsif jsonb_typeof(xv) = 'string' then cn := cn || kx; ct := ct || 8; cp := cp || proto.nbt_text(xv #>> '{}');
          else raise exception 'component:% of % is not supported by dbcraft', kx, k; end if;
        end loop;
        names := names || k; types := types || 10; pays := pays || mc.comp_compound(cn, ct, cp);
      end;
    end if;
  end loop;
  if v ? 'insertion' then names := names || 'insertion'::text; types := types || 8; pays := pays || proto.nbt_text(v ->> 'insertion'); end if;
  if v ? 'font' then names := names || 'font'::text; types := types || 8; pays := pays || proto.nbt_text(v ->> 'font'); end if;
  if v ? 'extra' then
    if jsonb_typeof(v -> 'extra') <> 'array' or jsonb_array_length(v -> 'extra') = 0 then raise exception 'component:%', mc.comp_err_text(v); end if;
    for x in select * from jsonb_array_elements(v -> 'extra') loop
      select * into sub from mc.comp_enc(x, p_me, p_depth + 1); ex := ex || x; et := et || sub.t; ep := ep || sub.payload;
    end loop;
    names := names || 'extra'::text; types := types || 9; pays := pays || mc.comp_list(ex, et, ep);
  end if;
  -- a literal with nothing else is a bare string
  if cardinality(names) = 1 and names[1] = 'text' then t := 8; payload := pays[1]; return; end if;
  t := 10; payload := mc.comp_compound(names, types, pays);
end $$;

-- a list component: the first one with the rest added to its `extra` (Component.copy().append)
create or replace function mc.comp_append(p_first jsonb, p_rest jsonb, p_me mc.player, p_depth int, out t int, out payload bytea) language plpgsql stable as $$
declare f jsonb; ex jsonb;
begin
  f := case when jsonb_typeof(p_first) = 'string' then jsonb_build_object('text', p_first) when jsonb_typeof(p_first) = 'object' then p_first
            else jsonb_build_object('extra', p_rest) end;
  if jsonb_typeof(p_first) = 'array' then raise exception 'component:nested lists are not supported by dbcraft'; end if;
  ex := coalesce(f -> 'extra', '[]'::jsonb) || p_rest;
  select e.t, e.payload into t, payload from mc.comp_enc(f || jsonb_build_object('extra', ex), p_me, p_depth + 1) e;
end $$;

-- the network NBT of a component value (a root tag: type byte + payload); an exception 'component:...' for an invalid one
create or replace function mc.comp_root(v jsonb, p_me mc.player) returns bytea language plpgsql stable as $$
declare r record;
begin
  select * into r from mc.comp_enc(v, p_me);
  return set_byte('\x00'::bytea, 0, r.t) || r.payload;
end $$;

-- the argument parser (mc.cmd_arg, sql/811): one SNBT value, decoded now (an invalid component is an argument error at the start of the value)
create or replace function mc.rd_component(s text, cur int) returns mc.cmd_ap language plpgsql stable as $$
declare r mc.cmd_ap; start int := mc.rd_skip_ws(s, cur); err text;
begin
  r := mc.snbt_value(s, cur); if r.ex_key is not null then return r; end if;
  begin
    perform mc.comp_root(r.val, null);
  exception when others then
    err := sqlerrm;
    if err like 'component:%' then return mc.ap_err('argument.component.invalid', jsonb_build_array(substr(err, 11)), start); end if;
    return mc.ap_err('argument.component.invalid', jsonb_build_array('dbcraft cannot decode this component: ' || err), start);
  end;
  return mc.ap_ok(r.pos, r.val);
end $$;

------------------------------------------------------------------------------------------------ /tellraw and /title
-- the component for a target (selectors resolved against the executor); an invalid one at execution (a selector that does not parse) is the command failing
create or replace function mc.cmd_component_for(me mc.player, v jsonb) returns bytea language plpgsql stable as $$
begin return mc.comp_root(v, mc.cmd_me(me.uuid)); end $$;

create or replace function mc.cmd_run_tellraw(me mc.player, lvl int, input text, sig text, args jsonb) returns void language plpgsql as $$
declare tgts mc.player[]; t mc.player;
begin
  tgts := mc.cmd_players(me, args -> 'targets'); if tgts is null then return; end if;
  foreach t in array tgts loop
    insert into mc.play_out (conn_id, data) values (t.conn_id, mc.pkt_system_chat(mc.cmd_component_for(me, args -> 'message')));
  end loop;
end $$;

-- /title <targets> (title|subtitle|actionbar) <component> | times <fadeIn> [<stay> [<fadeOut>]] | clear | reset.  Each target gets the packet, the executor the message
-- (commands.title.<what>.single / .multiple).  `times` keeps the three numbers it is given (the others as the server's defaults 10 70 20 would change nothing here: a missing one is
-- the player's current, which the server tracks as the defaults).
create or replace function mc.cmd_run_title(me mc.player, lvl int, input text, sig text, args jsonb) returns void language plpgsql as $$
declare tgts mc.player[]; t mc.player; what text := split_part(sig, '/', 3); pkt text; body bytea; key text;
begin
  tgts := mc.cmd_players(me, args -> 'targets'); if tgts is null then return; end if;
  foreach t in array tgts loop
    if what in ('title', 'subtitle', 'actionbar') then
      pkt := case what when 'title' then 'set_title_text' when 'subtitle' then 'set_subtitle_text' else 'set_action_bar_text' end;
      body := mc.cmd_component_for(me, args -> 'title');
    elsif what = 'times' then
      pkt := 'set_titles_animation'; body := proto.i32(coalesce((args ->> 'fadeIn')::int, 10)) || proto.i32(coalesce((args ->> 'stay')::int, 70)) || proto.i32(coalesce((args ->> 'fadeOut')::int, 20));
    elsif what = 'clear' then pkt := 'clear_titles'; body := proto.bool(false);
    else pkt := 'clear_titles'; body := proto.bool(true); end if;
    insert into mc.play_out (conn_id, data) values (t.conn_id, mc.cb(pkt, body));
  end loop;
  key := case what when 'clear' then 'commands.title.cleared' when 'reset' then 'commands.title.reset' when 'times' then 'commands.title.times' else 'commands.title.show.' || what end;
  if cardinality(tgts) = 1 then perform mc.cmd_success(me, mc.tc_translate(key || '.single', array[mc.tc_player(tgts[1].uuid, tgts[1].name)]));
  else perform mc.cmd_success(me, mc.tc_translate(key || '.multiple', array[mc.tc_arg_int(cardinality(tgts))])); end if;
end $$;
