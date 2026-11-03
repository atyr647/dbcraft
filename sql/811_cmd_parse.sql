-- Commands, part 2: a Brigadier-style parser that walks the command graph (mc.cmd_node, sql/810) for the player's permission level.
--
-- Everything the dispatcher decides about SYNTAX comes from the graph and the algorithm of com.mojang.brigadier.CommandDispatcher (parseNodes / execute, read
-- from the 26.3 bytecode in the library jar): which node matches, backtracking over argument alternatives, which exception is reported, and where the error
-- cursor is (the cursor selects the part of the input vanilla underlines in red).  The argument parsers below follow the vanilla classes of the same names
-- (EntitySelectorParser, EntitySelectorOptions, Vec3Argument, TimeArgument, ...).  Messages are translation keys of the 26.3 language file.
--
-- A value is parsed to JSON: numbers as numbers, text as text, an entity argument as a selector object (resolved at execution by sql/812).
-- Not covered (and said so in the error text, never silently wrong): item components `item[...]`, the selector options
-- advancements nbt predicate scores x_rotation y_rotation, argument types other than those listed in mc.cmd_arg.

drop type if exists mc.cmd_ap cascade;
create type mc.cmd_ap as (pos int, val jsonb, ex_key text, ex_args jsonb, ex_cursor int);       -- one argument parse: new cursor + value, or the exception
drop type if exists mc.cmd_pr cascade;
create type mc.cmd_pr as (pos int, nerr int, ex_key text, ex_args jsonb, ex_cursor int, path int[], top int[], args jsonb);   -- Brigadier's ParseResults

create or replace function mc.ap_ok(p_pos int, p_val jsonb default null) returns mc.cmd_ap language sql immutable as $$ select row(p_pos, p_val, null, null, null)::mc.cmd_ap $$;
create or replace function mc.ap_err(p_key text, p_args jsonb, p_cursor int) returns mc.cmd_ap language sql immutable as $$ select row(null, null, p_key, p_args, p_cursor)::mc.cmd_ap $$;
-- "dbcraft cannot do this" errors carry literal text (key starts with '!'), never a vanilla key
create or replace function mc.ap_unsupported(p_what text, p_cursor int) returns mc.cmd_ap language sql immutable as $$
  select mc.ap_err('!dbcraft does not support ' || p_what || ' yet', null, p_cursor) $$;

------------------------------------------------------------------------------------------------ StringReader
create or replace function mc.rd_end(s text, cur int, pat text) returns int language sql immutable as $$
  select cur + coalesce(length((regexp_match(substr(s, cur + 1), '^' || pat || '*'))[1]), 0) $$;
-- isAllowedInUnquotedString: 0-9 A-Z a-z _ - . +        isAllowedNumber: 0-9 . -
create or replace function mc.rd_unquoted_end(s text, cur int) returns int language sql immutable as $$ select mc.rd_end(s, cur, '[0-9A-Za-z_.+-]') $$;
create or replace function mc.rd_number_end(s text, cur int) returns int language sql immutable as $$ select mc.rd_end(s, cur, '[0-9.-]') $$;
create or replace function mc.rd_skip_ws(s text, cur int) returns int language sql immutable as $$ select mc.rd_end(s, cur, '[ \t\n\r]') $$;

-- readString: a quoted string (with \\ and \" escapes) or an unquoted one
create or replace function mc.rd_string(s text, cur int) returns mc.cmd_ap language plpgsql immutable as $$
declare q text := substr(s, cur + 1, 1); p int; ch text; out text := ''; esc boolean := false;
begin
  if q in ('"', '''') then
    p := cur + 1;
    while p < length(s) loop
      ch := substr(s, p + 1, 1); p := p + 1;
      if esc then
        if ch = q or ch = '\' then out := out || ch; esc := false;
        else return mc.ap_err('parsing.quote.escape', jsonb_build_array(ch), p - 1); end if;
      elsif ch = '\' then esc := true;
      elsif ch = q then return mc.ap_ok(p, to_jsonb(out));
      else out := out || ch; end if;
    end loop;
    return mc.ap_err('parsing.quote.expected.end', null, p);
  end if;
  p := mc.rd_unquoted_end(s, cur);
  return mc.ap_ok(p, to_jsonb(substr(s, cur + 1, p - cur)));
end $$;

create or replace function mc.rd_int(s text, cur int, lo bigint default null, hi bigint default null) returns mc.cmd_ap language plpgsql immutable as $$
declare e int := mc.rd_number_end(s, cur); tok text := substr(s, cur + 1, e - cur); v bigint;
begin
  if tok = '' then return mc.ap_err('parsing.int.expected', null, cur); end if;
  if tok !~ '^-?[0-9]+$' or length(regexp_replace(tok, '^-', '')) > 10 then return mc.ap_err('parsing.int.invalid', jsonb_build_array(tok), cur); end if;
  v := tok::bigint;
  if v < -2147483648 or v > 2147483647 then return mc.ap_err('parsing.int.invalid', jsonb_build_array(tok), cur); end if;
  if lo is not null and v < lo then return mc.ap_err('argument.integer.low', jsonb_build_array(lo, v), cur); end if;
  if hi is not null and v > hi then return mc.ap_err('argument.integer.big', jsonb_build_array(hi, v), cur); end if;
  return mc.ap_ok(e, to_jsonb(v));
end $$;

create or replace function mc.rd_double(s text, cur int, lo float8 default null, hi float8 default null, kind text default 'double') returns mc.cmd_ap language plpgsql immutable as $$
declare e int := mc.rd_number_end(s, cur); tok text := substr(s, cur + 1, e - cur); v float8;
begin
  if tok = '' then return mc.ap_err('parsing.' || kind || '.expected', null, cur); end if;
  if tok !~ '^-?([0-9]+\.?[0-9]*|\.[0-9]+)$' then return mc.ap_err('parsing.' || kind || '.invalid', jsonb_build_array(tok), cur); end if;
  v := tok::float8;
  if lo is not null and v < lo then return mc.ap_err('argument.' || kind || '.low', jsonb_build_array(lo, v), cur); end if;
  if hi is not null and v > hi then return mc.ap_err('argument.' || kind || '.big', jsonb_build_array(hi, v), cur); end if;
  return mc.ap_ok(e, to_jsonb(v));
end $$;

------------------------------------------------------------------------------------------------ ranges (MinMaxBounds)
-- "5", "..5", "5..", "1..5": all errors carry the cursor of the start of the range.  Returns val = [min, max] (null = open).
create or replace function mc.rd_range(s text, cur int, whole boolean default false) returns mc.cmd_ap language plpgsql immutable as $$
declare p int := cur; e int; a text; b text; lo float8; hi float8; n int := length(s);
begin
  if p >= n then return mc.ap_err('argument.range.empty', null, cur); end if;
  -- the first number stops before ".." (a '.' that starts ".." is not part of a number)
  e := p; while e < n and substr(s, e + 1, 1) ~ '[0-9.-]' and not (substr(s, e + 1, 2) = '..') loop e := e + 1; end loop;
  a := substr(s, p + 1, e - p); p := e;
  if substr(s, p + 1, 2) = '..' then
    p := p + 2; e := p;
    while e < n and substr(s, e + 1, 1) ~ '[0-9.-]' and not (substr(s, e + 1, 2) = '..') loop e := e + 1; end loop;
    b := substr(s, p + 1, e - p); p := e;
    if a = '' and b = '' then return mc.ap_err('argument.range.empty', null, cur); end if;
  else
    if a = '' then return mc.ap_err('argument.range.empty', null, cur); end if;
    b := a;
  end if;
  begin
    lo := nullif(a, '')::float8; hi := nullif(b, '')::float8;
  exception when others then return mc.ap_err('argument.range.empty', null, cur); end;
  if whole and (a ~ '\.' or b ~ '\.') then return mc.ap_err('parsing.int.invalid', jsonb_build_array(case when a ~ '\.' then a else b end), cur); end if;   -- (verified)
  if lo is not null and hi is not null and lo > hi then return mc.ap_err('argument.range.swapped', null, cur); end if;
  return mc.ap_ok(p, jsonb_build_array(lo, hi));
end $$;

------------------------------------------------------------------------------------------------ entity selectors (EntitySelectorParser)
-- val = {kind, name?, uuid?, limit, sort, incl, name_eq, name_ne[], dist[min,max], gm_eq, gm_ne[], type_eq, type_ne[], level[min,max], x, y, z}
-- kind: a e p r s n (selectors) | name | uuid.   incl = "includesEntities" (the selector can select things that are not players)
create or replace function mc.sel_parse(s text, cur int, allow boolean) returns mc.cmd_ap language plpgsql stable as $$
declare
  p int := cur; c text; n int := length(s);
  kind text; lim int; sort text := 'arbitrary'; incl boolean := false;
  name_eq text; name_ne text[] := '{}'; dmin float8; dmax float8; dist_set boolean := false; gm_eq int; gm_ne int[] := '{}'; type_eq text; type_ne text[] := '{}';
  lmin float8; lmax float8; level_set boolean := false; px float8; py float8; pz float8;
  has_name_eq boolean := false; has_name_ne boolean := false; limited boolean := false; sorted boolean := false; has_gm_eq boolean := false; has_gm_ne boolean := false;
  type_limited boolean := false; type_ne_set boolean := false; never boolean := false; pdx float8; pdy float8; pdz float8; has_team_eq boolean := false; has_team_ne boolean := false;
  i int; key text; r mc.cmd_ap; neg boolean; start int; v text; e int; rl text; gm int;
begin
  if substr(s, p + 1, 1) = '@' then
    if not allow then return mc.ap_err('argument.entity.selector.not_allowed', null, p); end if;
    p := p + 1;
    if p >= n then return mc.ap_err('argument.entity.selector.missing', null, p); end if;
    c := substr(s, p + 1, 1);
    case c
      when 'a' then kind := 'a'; lim := null; incl := false; sort := 'arbitrary';
      when 'e' then kind := 'e'; lim := null; incl := true;  sort := 'arbitrary';
      when 'p' then kind := 'p'; lim := 1;    incl := false; sort := 'nearest';
      when 'r' then kind := 'r'; lim := 1;    incl := false; sort := 'random';
      when 's' then kind := 's'; lim := 1;    incl := true;
      when 'n' then kind := 'n'; lim := 1;    incl := true;  sort := 'nearest';
      else return mc.ap_err('argument.entity.selector.unknown', jsonb_build_array('@' || c), p);
    end case;
    p := p + 1;
    if substr(s, p + 1, 1) = '[' then
      p := mc.rd_skip_ws(s, p + 1);
      while p < n and substr(s, p + 1, 1) <> ']' loop
        p := mc.rd_skip_ws(s, p);
        i := p;
        r := mc.rd_string(s, p); if r.ex_key is not null then return r; end if;
        key := r.val #>> '{}'; p := r.pos;
        -- is the option known, and applicable here?
        if key not in ('name', 'distance', 'limit', 'sort', 'gamemode', 'type', 'level', 'x', 'y', 'z', 'dx', 'dy', 'dz', 'tag', 'team') then
          if key in ('advancements', 'nbt', 'predicate', 'scores', 'x_rotation', 'y_rotation') then
            return mc.ap_unsupported('the selector option ''' || key || '''', i);
          end if;
          return mc.ap_err('argument.entity.options.unknown', jsonb_build_array(key), i);
        end if;
        if (key = 'name' and has_name_eq) or (key = 'distance' and dist_set) or (key = 'level' and level_set) or (key = 'x' and px is not null)
           or (key = 'y' and py is not null) or (key = 'z' and pz is not null) or (key = 'limit' and (kind = 's' or limited)) or (key = 'sort' and (kind = 's' or sorted))
           or (key = 'gamemode' and has_gm_eq) or (key = 'type' and type_limited) or (key = 'dx' and pdx is not null) or (key = 'dy' and pdy is not null)
           or (key = 'dz' and pdz is not null) or (key = 'team' and has_team_eq) then
          return mc.ap_err('argument.entity.options.inapplicable', jsonb_build_array(key), i);
        end if;
        p := mc.rd_skip_ws(s, p);
        if p >= n or substr(s, p + 1, 1) <> '=' then return mc.ap_err('argument.entity.options.valueless', jsonb_build_array(key), i); end if;
        p := mc.rd_skip_ws(s, p + 1);
        -- the value
        if key = 'name' then
          start := p; p := mc.rd_skip_ws(s, p); neg := substr(s, p + 1, 1) = '!'; if neg then p := mc.rd_skip_ws(s, p + 1); end if;
          r := mc.rd_string(s, p); if r.ex_key is not null then return r; end if;
          v := r.val #>> '{}'; p := r.pos;
          if has_name_ne and not neg then return mc.ap_err('argument.entity.options.inapplicable', jsonb_build_array('name'), start); end if;
          if neg then has_name_ne := true; name_ne := name_ne || v; else has_name_eq := true; name_eq := v; end if;
        elsif key = 'distance' then
          r := mc.rd_range(s, p); if r.ex_key is not null then return r; end if;
          dmin := (r.val ->> 0)::float8; dmax := (r.val ->> 1)::float8;
          if coalesce(dmin, 0) < 0 or coalesce(dmax, 0) < 0 then return mc.ap_err('argument.entity.options.distance.negative', null, p); end if;
          dist_set := true; p := r.pos;
        elsif key = 'level' then
          r := mc.rd_range(s, p, true); if r.ex_key is not null then return r; end if;
          lmin := (r.val ->> 0)::float8; lmax := (r.val ->> 1)::float8;
          if coalesce(lmin, 0) < 0 or coalesce(lmax, 0) < 0 then return mc.ap_err('argument.entity.options.level.negative', null, p); end if;
          level_set := true; incl := false; p := r.pos;
        elsif key = 'limit' then
          start := p; r := mc.rd_int(s, p); if r.ex_key is not null then return r; end if;
          if (r.val #>> '{}')::int < 1 then return mc.ap_err('argument.entity.options.limit.toosmall', null, start); end if;
          lim := (r.val #>> '{}')::int; limited := true; p := r.pos;
        elsif key = 'sort' then
          start := p; e := mc.rd_unquoted_end(s, p); v := substr(s, p + 1, e - p);
          if v not in ('nearest', 'furthest', 'random', 'arbitrary') then return mc.ap_err('argument.entity.options.sort.irreversible', jsonb_build_array(v), start); end if;
          sort := v; sorted := true; p := e;
        elsif key = 'gamemode' then
          start := p; p := mc.rd_skip_ws(s, p); neg := substr(s, p + 1, 1) = '!'; if neg then p := mc.rd_skip_ws(s, p + 1); end if;
          e := mc.rd_unquoted_end(s, p); v := substr(s, p + 1, e - p);
          gm := case v when 'survival' then 0 when 'creative' then 1 when 'adventure' then 2 when 'spectator' then 3 end;
          if gm is null then return mc.ap_err('argument.entity.options.mode.invalid', jsonb_build_array(v), start); end if;
          if has_gm_ne and not neg then return mc.ap_err('argument.entity.options.inapplicable', jsonb_build_array('gamemode'), start); end if;
          if neg then has_gm_ne := true; gm_ne := gm_ne || gm; else has_gm_eq := true; gm_eq := gm; end if;
          incl := false; p := e;
        elsif key = 'type' then
          start := p; p := mc.rd_skip_ws(s, p); neg := substr(s, p + 1, 1) = '!'; if neg then p := mc.rd_skip_ws(s, p + 1); end if;
          if type_ne_set and not neg then return mc.ap_err('argument.entity.options.inapplicable', jsonb_build_array('type'), start); end if;
          if substr(s, p + 1, 1) = '#' then
            e := mc.rd_end(s, p + 1, '[0-9a-z_.:/-]'); v := substr(s, p + 2, e - p - 1);
            rl := case when v like '%:%' then v else 'minecraft:' || v end;
            if neg then type_ne_set := true;
              if exists (select 1 from ref.dp_tag_member where registry = 'minecraft:entity_type' and tag = rl and member = 'minecraft:player') then never := true; end if;
            else type_limited := true;
              if not exists (select 1 from ref.dp_tag_member where registry = 'minecraft:entity_type' and tag = rl and member = 'minecraft:player') then never := true; end if;
            end if;
            p := e;
          else
            e := mc.rd_end(s, p, '[0-9a-z_.:/-]'); v := substr(s, p + 1, e - p);
            rl := case when v like '%:%' then v else 'minecraft:' || v end;
            if not exists (select 1 from ref.registry where registry = 'minecraft:entity_type' and name = rl) then
              return mc.ap_err('argument.entity.options.type.invalid', jsonb_build_array(rl), start);
            end if;
            if neg then type_ne_set := true; type_ne := type_ne || rl; else type_eq := rl; type_limited := true; if rl = 'minecraft:player' then incl := false; end if; end if;
            p := e;
          end if;
        elsif key = 'tag' or key = 'team' then
          -- players here have no tags and no team: tag=x / team=x match nobody, tag=!x / team=!x everybody, tag= / team= (none) everybody, tag=! / team=! nobody
          start := p; p := mc.rd_skip_ws(s, p); neg := substr(s, p + 1, 1) = '!'; if neg then p := mc.rd_skip_ws(s, p + 1); end if;
          r := mc.rd_string(s, p); if r.ex_key is not null then return r; end if;
          v := r.val #>> '{}'; p := r.pos;
          if key = 'team' then
            if has_team_ne and not neg then return mc.ap_err('argument.entity.options.inapplicable', jsonb_build_array('team'), start); end if;
            if neg then has_team_ne := true; else has_team_eq := true; end if;
          end if;
          if (not neg and v <> '') or (neg and v = '') then never := true; end if;
        elsif key in ('dx', 'dy', 'dz') then
          r := mc.rd_double(s, p); if r.ex_key is not null then return r; end if;
          if key = 'dx' then pdx := (r.val #>> '{}')::float8; elsif key = 'dy' then pdy := (r.val #>> '{}')::float8; else pdz := (r.val #>> '{}')::float8; end if;
          p := r.pos;
        else   -- x y z
          r := mc.rd_double(s, p); if r.ex_key is not null then return r; end if;
          if key = 'x' then px := (r.val #>> '{}')::float8; elsif key = 'y' then py := (r.val #>> '{}')::float8; else pz := (r.val #>> '{}')::float8; end if;
          p := r.pos;
        end if;
        p := mc.rd_skip_ws(s, p);
        if p < n then
          if substr(s, p + 1, 1) = ',' then p := p + 1; continue; end if;
          if substr(s, p + 1, 1) <> ']' then return mc.ap_err('argument.entity.options.unterminated', null, p); end if;
        end if;
        exit;
      end loop;
      if p < n and substr(s, p + 1, 1) = ']' then p := p + 1;
      else return mc.ap_err('argument.entity.options.unterminated', null, p); end if;
    end if;
  else
    -- a name or a UUID (readString: quoted or not)
    r := mc.rd_string(s, p); if r.ex_key is not null then return r; end if;
    v := r.val #>> '{}';
    if v ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      return mc.ap_ok(r.pos, jsonb_build_object('kind', 'uuid', 'uuid', lower(v), 'limit', 1, 'sort', 'arbitrary', 'incl', true));
    end if;
    if v = '' or length(v) > 16 then return mc.ap_err('argument.entity.invalid', null, p); end if;
    return mc.ap_ok(r.pos, jsonb_build_object('kind', 'name', 'name', v, 'limit', 1, 'sort', 'arbitrary', 'incl', false));
  end if;
  return mc.ap_ok(p, jsonb_strip_nulls(jsonb_build_object('kind', kind, 'limit', lim, 'sort', sort, 'incl', incl, 'name_eq', name_eq, 'name_ne', to_jsonb(name_ne),
      'dist', case when dist_set then jsonb_build_array(dmin, dmax) end, 'gm_eq', gm_eq, 'gm_ne', to_jsonb(gm_ne), 'type_eq', type_eq, 'type_ne', to_jsonb(type_ne),
      'level', case when level_set then jsonb_build_array(lmin, lmax) end, 'x', px, 'y', py, 'z', pz, 'dx', pdx, 'dy', pdy, 'dz', pdz, 'never', case when never then true end)));
end $$;

------------------------------------------------------------------------------------------------ argument types
-- p_node: the argument node (its parser type and properties come from the row).  p_sel_ok: the source may use selectors (permission level 2).
create or replace function mc.cmd_arg(p_node int, s text, cur int, p_sel_ok boolean) returns mc.cmd_ap language plpgsql stable as $$
declare t text; pr bytea; r mc.cmd_ap; flags int; lo float8; hi float8; e int; v text; kind int; n int := length(s); p int; q int; unit text; f float8; ticks bigint; mn bigint;
  vals jsonb := '[]'; ex mc.cmd_ap; sel jsonb; rl text; coords text[] := '{}'; k int;
begin
  select argtype_name, argprops into t, pr from mc.cmd_node where id = p_node;
  case t
  when 'brigadier:bool' then
    r := mc.rd_string(s, cur); if r.ex_key is not null then return r; end if;
    v := r.val #>> '{}';
    if v = '' then return mc.ap_err('parsing.bool.expected', null, cur); end if;
    if v in ('true', 'false') then return mc.ap_ok(r.pos, to_jsonb(v = 'true')); end if;
    return mc.ap_err('parsing.bool.invalid', jsonb_build_array(v), cur);
  when 'brigadier:integer', 'brigadier:long' then
    flags := get_byte(pr, 0); lo := null; hi := null; k := 1;
    if t = 'brigadier:integer' then
      if flags & 1 = 1 then lo := proto.i32_read(pr, k); k := k + 4; end if;
      if flags & 2 = 2 then hi := proto.i32_read(pr, k); end if;
    end if;
    return mc.rd_int(s, cur, lo::bigint, hi::bigint);
  when 'brigadier:float', 'brigadier:double' then
    flags := get_byte(pr, 0); lo := null; hi := null; k := 1;
    if t = 'brigadier:float' then
      if flags & 1 = 1 then lo := proto.f32_read(pr, k); k := k + 4; end if; if flags & 2 = 2 then hi := proto.f32_read(pr, k); end if;
    else
      if flags & 1 = 1 then lo := proto.f64_read(pr, k); k := k + 8; end if; if flags & 2 = 2 then hi := proto.f64_read(pr, k); end if;
    end if;
    return mc.rd_double(s, cur, lo, hi, case when t = 'brigadier:float' then 'float' else 'double' end);
  when 'brigadier:string' then
    kind := get_byte(pr, 0);
    if kind = 2 then return mc.ap_ok(n, to_jsonb(substr(s, cur + 1))); end if;                 -- greedy: the rest, possibly empty
    if kind = 1 then return mc.rd_string(s, cur); end if;                                      -- phrase
    e := mc.rd_unquoted_end(s, cur); return mc.ap_ok(e, to_jsonb(substr(s, cur + 1, e - cur)));  -- word
  when 'minecraft:gamemode' then
    e := mc.rd_unquoted_end(s, cur); v := substr(s, cur + 1, e - cur);
    if v not in ('survival', 'creative', 'adventure', 'spectator') then return mc.ap_err('argument.gamemode.invalid', jsonb_build_array(v), e); end if;
    return mc.ap_ok(e, to_jsonb(v));
  when 'minecraft:entity' then
    flags := get_byte(pr, 0);        -- 1 = a single entity, 2 = players only
    r := mc.sel_parse(s, cur, p_sel_ok); if r.ex_key is not null then return r; end if;
    sel := r.val;
    if coalesce((sel ->> 'limit')::int, 2147483647) > 1 and flags & 1 = 1 then
      return mc.ap_err(case when flags & 2 = 2 then 'argument.player.toomany' else 'argument.entity.toomany' end, null, 0);
    elsif (sel ->> 'incl')::boolean and flags & 2 = 2 and sel ->> 'kind' <> 's' then
      return mc.ap_err('argument.player.entities', null, 0);
    end if;
    return mc.ap_ok(r.pos, sel);
  when 'minecraft:game_profile' then
    if substr(s, cur + 1, 1) = '@' then
      r := mc.sel_parse(s, cur, p_sel_ok); if r.ex_key is not null then return r; end if;
      if (r.val ->> 'incl')::boolean then return mc.ap_err('argument.player.entities', null, 0); end if;
      return r;
    end if;
    e := cur; while e < n and substr(s, e + 1, 1) <> ' ' loop e := e + 1; end loop;
    return mc.ap_ok(e, jsonb_build_object('kind', 'profile', 'name', substr(s, cur + 1, e - cur), 'limit', 1, 'sort', 'arbitrary', 'incl', false));
  when 'minecraft:message' then
    -- the rest of the line; every selector in it is parsed now (a syntax error in one is the error of the command), unknown selector TYPES are plain text
    p := cur; vals := '[]';
    if not p_sel_ok then return mc.ap_ok(n, jsonb_build_object('text', substr(s, cur + 1), 'parts', vals)); end if;       -- no selectors below level 2: plain text
    while p < n loop
      if substr(s, p + 1, 1) = '@' then
        r := mc.sel_parse(s, p, p_sel_ok);
        if r.ex_key is null then vals := vals || jsonb_build_array(jsonb_build_object('start', p - cur, 'end', r.pos - cur, 'sel', r.val)); p := r.pos;
        elsif r.ex_key in ('argument.entity.selector.missing', 'argument.entity.selector.unknown') then p := p + 1;
        else return r; end if;
      else p := p + 1; end if;
    end loop;
    return mc.ap_ok(n, jsonb_build_object('text', substr(s, cur + 1), 'parts', vals));
  when 'minecraft:item_stack', 'minecraft:item_predicate' then
    if t = 'minecraft:item_predicate' and substr(s, cur + 1, 1) = '*' then return mc.ap_ok(cur + 1, to_jsonb('*'::text)); end if;
    if substr(s, cur + 1, 1) = '#' then return mc.ap_unsupported('item tags', cur); end if;
    e := mc.rd_end(s, cur, '[0-9a-z_.:/-]'); v := substr(s, cur + 1, e - cur);
    rl := case when v like '%:%' then v else 'minecraft:' || v end;
    if not exists (select 1 from ref.registry where registry = 'minecraft:item' and name = rl) then
      return mc.ap_err('argument.item.id.invalid', jsonb_build_array(rl), case when t = 'minecraft:item_predicate' then e else cur end);   -- (verified: after the id for /clear, before it for /give)
    end if;
    if substr(s, e + 1, 1) in ('[', '{') then return mc.ap_unsupported('item components or NBT', e); end if;
    return mc.ap_ok(e, to_jsonb(rl));
  when 'minecraft:vec3' then
    -- three coordinates: x z of a plain integer are centred on the block (+0.5), y is not (WorldCoordinates.parseDouble)
    p := cur;
    if substr(s, p + 1, 1) = '^' then       -- local coordinates: left up forwards, each written ^ or ^number (LocalCoordinates.parse)
      for k in 1 .. 3 loop
        if substr(s, p + 1, 1) <> '^' then return mc.ap_err('argument.pos.mixed', null, p); end if;
        p := p + 1; q := p;
        if p < n and substr(s, p + 1, 1) <> ' ' then
          r := mc.rd_double(s, p); if r.ex_key is not null then return r; end if; p := r.pos;
        end if;
        coords := coords || ('^' || substr(s, q + 1, p - q));
        if k < 3 then if p < n and substr(s, p + 1, 1) = ' ' then p := p + 1; else return mc.ap_err('argument.pos3d.incomplete', null, cur); end if; end if;
      end loop;
      return mc.ap_ok(p, to_jsonb(coords));
    end if;
    for k in 1 .. 3 loop
      if p >= n then
        if k = 1 then return mc.ap_err('argument.pos.missing.double', null, cur); end if;
        return mc.ap_err('argument.pos3d.incomplete', null, cur);
      end if;
      if substr(s, p + 1, 1) = '^' then return mc.ap_err('argument.pos.mixed', null, p); end if;
      v := '';
      if substr(s, p + 1, 1) = '~' then v := '~'; p := p + 1; end if;
      q := p;
      if p < n and substr(s, p + 1, 1) <> ' ' then
        r := mc.rd_double(s, p); if r.ex_key is not null then return r; end if;
        p := r.pos; f := (r.val #>> '{}')::float8;
        v := v || substr(s, q + 1, p - q);
        if v !~ '^~' and substr(s, q + 1, p - q) !~ '\.' and k <> 2 then v := (f + 0.5)::text; end if;
      elsif v = '~' then null; else return mc.ap_err('argument.pos.missing.double', null, p); end if;
      coords := coords || v;
      if k < 3 then
        if p < n and substr(s, p + 1, 1) = ' ' then p := p + 1; else return mc.ap_err('argument.pos3d.incomplete', null, cur); end if;
      end if;
    end loop;
    return mc.ap_ok(p, to_jsonb(coords));
  when 'minecraft:rotation' then
    p := cur;
    for k in 1 .. 2 loop
      if p >= n then return mc.ap_err('argument.rotation.incomplete', null, cur); end if;
      v := '';
      if substr(s, p + 1, 1) = '~' then v := '~'; p := p + 1; end if;
      q := p;
      if p < n and substr(s, p + 1, 1) <> ' ' then
        r := mc.rd_double(s, p); if r.ex_key is not null then return r; end if; p := r.pos; v := v || substr(s, q + 1, p - q);
      elsif v <> '~' then return mc.ap_err('argument.pos.missing.double', null, p); end if;
      coords := coords || v;
      if k < 2 then if p < n and substr(s, p + 1, 1) = ' ' then p := p + 1; else return mc.ap_err('argument.rotation.incomplete', null, cur); end if; end if;
    end loop;
    return mc.ap_ok(p, to_jsonb(coords));
  when 'minecraft:time' then
    -- <float>[d|s|t]: days, seconds, ticks
    mn := proto.i32_read(pr, 0);
    r := mc.rd_double(s, cur, null, null, 'float'); if r.ex_key is not null then return r; end if;
    e := mc.rd_unquoted_end(s, r.pos); unit := substr(s, r.pos + 1, e - r.pos);
    if unit not in ('', 'd', 's', 't') then return mc.ap_err('argument.time.invalid_unit', null, e); end if;
    ticks := round((r.val #>> '{}')::float8 * case unit when 'd' then 24000 when 's' then 20 else 1 end);
    if ticks < mn then return mc.ap_err('argument.time.tick_count_too_low', jsonb_build_array(mn, ticks), cur); end if;
    return mc.ap_ok(e, to_jsonb(ticks));
  when 'minecraft:resource' then
    e := mc.rd_end(s, cur, '[0-9a-z_.:/-]'); v := substr(s, cur + 1, e - cur);
    rl := case when v like '%:%' then v else 'minecraft:' || v end;
    -- the registry key of the argument is in its properties (a VarInt-length string)
    if not exists (select 1 from ref.dp_entry where registry = convert_from(substring(pr from 2), 'UTF8') and name = rl) then
      return mc.ap_err('argument.resource.not_found', jsonb_build_array(rl, convert_from(substring(pr from 2), 'UTF8')), e);
    end if;
    return mc.ap_ok(e, to_jsonb(rl));
  when 'minecraft:resource_location' then
    e := mc.rd_end(s, cur, '[0-9a-z_.:/-]'); v := substr(s, cur + 1, e - cur);
    return mc.ap_ok(e, to_jsonb(case when v like '%:%' then v else 'minecraft:' || v end));
  else
    return mc.ap_unsupported('the argument type ' || coalesce(t, '?'), cur);
  end case;
end $$;

------------------------------------------------------------------------------------------------ the dispatcher's parse (CommandDispatcher.parseNodes / execute)
create or replace function mc.cmd_parse_nodes(p_node int, s text, cur int, lvl int, depth int, p_sel_ok boolean) returns mc.cmd_pr language plpgsql stable as $$
declare
  n int := length(s); word text := (regexp_match(substr(s, cur + 1), '^[^ ]*'))[1]; lit_match boolean;
  ch record; ap mc.cmd_ap; pos int; sub mc.cmd_pr; cands mc.cmd_pr[] := '{}'; cand mc.cmd_pr; best mc.cmd_pr; best_rank int; rank int;
  nerr int := 0; first_key text; first_args jsonb; first_cur int; val jsonb; a jsonb;
begin
  if depth > 40 then return row(cur, 0, null, null, null, '{}', '{}', '{}'::jsonb)::mc.cmd_pr; end if;
  select exists (select 1 from mc.cmd_child c join mc.cmd_node x on x.id = c.child where c.parent = p_node and x.kind = 1 and x.name = word) into lit_match;
  -- relevant nodes (CommandNode.getRelevantNodes): a literal that equals the next word, or else every argument child
  for ch in
    select x.*, c.pos as cpos from mc.cmd_child c join mc.cmd_node x on x.id = c.child
     where c.parent = p_node and ((lit_match and x.kind = 1 and x.name = word) or (not lit_match and x.kind = 2)) order by c.pos
  loop
    continue when ch.min_level > lvl;                                     -- canUse(source)
    val := null;
    if ch.kind = 1 then pos := cur + length(ch.name);
    else
      ap := mc.cmd_arg(ch.id, s, cur, p_sel_ok);
      if ap.ex_key is not null then
        nerr := nerr + 1;
        if nerr = 1 then first_key := ap.ex_key; first_args := ap.ex_args; first_cur := ap.ex_cursor; end if;
        continue;
      end if;
      pos := ap.pos; val := ap.val;
    end if;
    if pos < n and substr(s, pos + 1, 1) <> ' ' then                      -- dispatcherExpectedArgumentSeparator
      nerr := nerr + 1;
      if nerr = 1 then first_key := 'command.expected.separator'; first_args := null; first_cur := pos; end if;
      continue;
    end if;
    a := case when ch.kind = 2 then jsonb_build_object(ch.name, val) else '{}'::jsonb end;
    if n - pos >= (case when ch.redirect is null then 2 else 1 end) then
      if ch.redirect is not null then
        sub := mc.cmd_parse_nodes(ch.redirect, s, pos + 1, lvl, depth + 1, p_sel_ok);
        return row(sub.pos, sub.nerr, sub.ex_key, sub.ex_args, sub.ex_cursor, ch.id || sub.path, array[ch.id], a || sub.args)::mc.cmd_pr;
      end if;
      sub := mc.cmd_parse_nodes(ch.id, s, pos + 1, lvl, depth + 1, p_sel_ok);
      cands := cands || row(sub.pos, sub.nerr, sub.ex_key, sub.ex_args, sub.ex_cursor, ch.id || sub.path, ch.id || sub.top, a || sub.args)::mc.cmd_pr;
    else
      cands := cands || row(pos, 0, null, null, null, array[ch.id], array[ch.id], a)::mc.cmd_pr;
    end if;
  end loop;
  if cardinality(cands) > 0 then
    -- potentials.sort: a parse that consumed the whole input first, then one without exceptions (stable)
    best := null; best_rank := 99;
    foreach cand in array cands loop
      rank := (case when cand.pos < n then 2 else 0 end) + (case when cand.nerr > 0 then 1 else 0 end);
      if rank < best_rank then best := cand; best_rank := rank; end if;
    end loop;
    return best;
  end if;
  return row(cur, nerr, first_key, first_args, first_cur, '{}', '{}', '{}'::jsonb)::mc.cmd_pr;
end $$;

drop type if exists mc.cmd_res cascade;
create type mc.cmd_res as (ok boolean, ex_key text, ex_args jsonb, ex_cursor int, path int[], top int[], args jsonb, final_node int);

-- CommandDispatcher.execute's decision on a parse: the exception to report, or the executable node reached
create or replace function mc.cmd_parse(p_level int, p_input text) returns mc.cmd_res language plpgsql stable as $$
declare pr mc.cmd_pr; n int := length(p_input); fin int; ex boolean; res mc.cmd_res;
begin
  pr := mc.cmd_parse_nodes(0, p_input, 0, p_level, 0, p_level >= 2);
  res.path := pr.path; res.top := pr.top; res.args := pr.args; res.ok := false;
  if pr.pos < n then
    if pr.nerr = 1 then res.ex_key := pr.ex_key; res.ex_args := pr.ex_args; res.ex_cursor := pr.ex_cursor;
    elsif cardinality(pr.top) = 0 then res.ex_key := 'command.unknown.command'; res.ex_cursor := pr.pos;
    else res.ex_key := 'command.unknown.argument'; res.ex_cursor := pr.pos; end if;
    return res;
  end if;
  fin := pr.path[cardinality(pr.path)];
  select executable into ex from mc.cmd_node where id = fin;
  if fin is null or not coalesce(ex, false) then res.ex_key := 'command.unknown.command'; res.ex_cursor := pr.pos; return res; end if;
  res.ok := true; res.final_node := fin; return res;
end $$;
