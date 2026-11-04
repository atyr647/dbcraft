-- The update_attributes entries of the add_entity bundle for a player that wears and holds nothing (docs/PERF-CAPACITY.md).
-- mc.pairing_attrs reads the six equipment slots of the player and joins what it finds with ref.item_attr: 0.17-0.28 ms a call, and a bundle is built for every target that gains a viewer
-- (44 a tick with 500 walkers, 433 in a crowd).  For a player whose six visible slots are empty (the case in every scripted test and in most of a lobby) the answer depends on three values only:
-- the game mode the attribute modifiers were last computed for, whether it sprints, and the bit mask of the attributes in its map.  mc.attr_memo keeps it per combination (a handful of rows).
-- It is a cache of mc.pairing_attrs of a player without items, filled by the first caller; after the reference data of the attributes is reloaded (tools/load_item_components.py) run
-- `truncate mc.attr_memo` (a restarted server does not need it: the table is unlogged).  tests/sql/985 compares it with mc.pairing_attrs for players without items.
create unlogged table if not exists mc.attr_memo (
    gm      int     not null,
    sprint  boolean not null,
    seen    bigint  not null,
    entries bytea[],                          -- null: the player has no attribute to announce (mc.pairing_attrs is null)
    primary key (gm, sprint, seen)
);

create or replace function mc.attr_memo(p_gm int, p_sprint boolean, p_seen bigint) returns bytea[] language plpgsql volatile as $$
declare r bytea[];
begin
  select m.entries into r from mc.attr_memo m where m.gm = p_gm and m.sprint = p_sprint and m.seen = p_seen;
  if found then return r; end if;
  r := mc.pairing_attrs('00000000-0000-0000-0000-000000000000'::uuid, 0, p_gm, p_sprint, p_seen);          -- (the nil uuid owns no inventory rows: the same as any player with empty slots)
  insert into mc.attr_memo (gm, sprint, seen, entries) values (p_gm, p_sprint, p_seen, r) on conflict do nothing;
  return r;
end $$;
