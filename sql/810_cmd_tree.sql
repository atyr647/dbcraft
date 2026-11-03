-- Commands, part 1: the command graph as rows, and the `commands` packet generated from them.
--
-- vanilla sends every player a `commands` packet at join (and again when the player's permission level changes): the Brigadier graph of every command the
-- player may use, so that the client can tab-complete and colour what is typed.  Here the graph is rows:
--
--   mc.cmd_node   one row per node: kind (0 root, 1 literal, 2 argument), name, executable, restricted, redirect, the argument parser (registry id, its name
--                 and the serialized properties), the suggestion provider, and min_level = the permission level needed to see it
--   mc.cmd_child  the edges, in the order vanilla registers its commands (the order is part of the packet)
--
-- The rows are loaded by tools/load_command_tree.py from a recording of a level-4 operator's join (Mojang's data is never committed).  The same rows drive
-- the command dispatcher (sql/811: the parser walks the graph the player is allowed to see, so a command that is not in the tree is "unknown" exactly as in
-- vanilla), /help (sql/815: usage text derived from the graph), and the tests that compare the generated packet with the recordings for all levels.
--
-- The packet for a level is a breadth-first numbering of the nodes visible at that level, starting at the root: children in registration order, then the
-- node's redirect target, each node numbered once (ClientboundCommandsPacket.enumerateNodes).  A node is visible when its own min_level is at most the
-- player's level and its parent is visible.  Levels 0 and 1 give the same tree in 26.3 (checked against recordings).

create table if not exists mc.cmd_node (
    id           int primary key,
    kind         smallint not null check (kind in (0, 1, 2)),
    name         text,
    executable   boolean not null,
    restricted   boolean not null,               -- the packet's "restricted" flag (0x20): the node has a permission requirement
    redirect     int references mc.cmd_node (id) deferrable initially deferred,
    argtype      int,                            -- registry minecraft:command_argument_type id (kind = 2)
    argtype_name text,
    argprops     bytea,                          -- the parser's serialized properties, exactly as sent
    suggestions  text,                           -- suggestion provider (resource location), or null
    min_level    smallint not null default 0 check (min_level between 0 and 4)
);
create table if not exists mc.cmd_child (
    parent int not null references mc.cmd_node (id) deferrable initially deferred,
    pos    int not null,
    child  int not null references mc.cmd_node (id) deferrable initially deferred,
    primary key (parent, pos)
);
create index if not exists cmd_child_child on mc.cmd_child (child);
-- the generated packet bodies, one per permission level 0..4 (filled by mc.cmd_tree_rebuild, which the loader calls)
create table if not exists mc.cmd_tree_cache (level int primary key check (level between 0 and 4), body bytea not null, nodes int not null);

-- Breadth-first numbering of the nodes visible at a level: (old id, new id) in new-id order.
create or replace function mc.cmd_tree_order(p_level int) returns table (old_id int, new_id int) language plpgsql stable as $$
declare
  queue int[] := array[0]; head int := 1; cur int; seen boolean[] := '{}'; n int := 0; kids int[]; k int; red int;
begin
  while head <= cardinality(queue) loop
    cur := queue[head]; head := head + 1;
    continue when coalesce(seen[cur + 1], false);
    seen[cur + 1] := true; old_id := cur; new_id := n; n := n + 1; return next;
    select coalesce(array_agg(c.child order by c.pos), '{}') into kids
      from mc.cmd_child c join mc.cmd_node x on x.id = c.child where c.parent = cur and x.min_level <= p_level;
    queue := queue || kids;
    select redirect into red from mc.cmd_node where id = cur;
    if red is not null then queue := queue || red; end if;
  end loop;
end $$;

-- The `commands` packet body for a level: VarInt node count, the nodes, VarInt root index (0).
create or replace function mc.cmd_tree_body(p_level int) returns table (body bytea, nodes int) language plpgsql stable as $$
declare ord int[]; m int[] := '{}'; r record; parts bytea[] := '{}'; kids int[]; ids int[];
begin
  select array_agg(o.old_id order by o.new_id) into ord from mc.cmd_tree_order(p_level) o;
  if ord is null then return; end if;
  for i in 1 .. cardinality(ord) loop m[ord[i] + 1] := i - 1; end loop;
  for i in 1 .. cardinality(ord) loop
    select * into r from mc.cmd_node where id = ord[i];
    select coalesce(array_agg(m[c.child + 1] order by c.pos) filter (where m[c.child + 1] is not null), '{}') into kids from mc.cmd_child c where c.parent = r.id;
    parts := parts || (
      proto.i8(r.kind | (case when r.executable then 4 else 0 end) | (case when r.redirect is not null then 8 else 0 end)
               | (case when r.suggestions is not null then 16 else 0 end) | (case when r.restricted then 32 else 0 end))
      || proto.varint(cardinality(kids)) || coalesce((select string_agg(proto.varint(x), '\x'::bytea order by o) from unnest(kids) with ordinality t(x, o)), '\x'::bytea)
      || case when r.redirect is not null then proto.varint(m[r.redirect + 1]) else '\x'::bytea end
      || case when r.kind > 0 then proto.string(r.name) else '\x'::bytea end
      || case when r.kind = 2 then proto.varint(r.argtype) || r.argprops else '\x'::bytea end
      || case when r.suggestions is not null then proto.string(r.suggestions) else '\x'::bytea end);
  end loop;
  body := proto.varint(cardinality(ord)) || proto.cat(parts) || proto.varint(0); nodes := cardinality(ord); return next;
end $$;

create or replace function mc.cmd_tree_rebuild() returns void language plpgsql as $$
begin
  delete from mc.cmd_tree_cache;
  insert into mc.cmd_tree_cache (level, body, nodes) select l, t.body, t.nodes from generate_series(0, 4) l, lateral mc.cmd_tree_body(l) t;
end $$;

-- net.commands_body (sql/150) with the generated tree: the join burst and /op /deop ask for the packet of the player's level.  Falls back to the static
-- level-0 packet when the graph has not been loaded.
create or replace function net.commands_body(p_level int) returns bytea language sql stable as $$
  select coalesce((select body from mc.cmd_tree_cache where level = least(greatest(coalesce(p_level, 0), 0), 4)),
                  (select body from net.static_packet where packet = 'minecraft:commands')) $$;

create or replace function mc.pkt_commands(p_level int) returns bytea language sql stable as $$
  select mc.cb('commands', net.commands_body(p_level)) $$;
