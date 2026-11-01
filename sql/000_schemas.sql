-- dbcraft: schemas.  Applied first, by tools/migrate.sh.
--   ref   reference data produced by the Minecraft data generator (blocks, items, registries, packet ids). Loaded, never edited.
--   proto wire-format codec: VarInt, strings, numbers, UUIDs, positions (pure functions).
--   mc    the game: world, players, inventory, rules, commands, tick.
--   net   connections: inbox/outbox queues and per-connection protocol state.
create schema if not exists ref;
create schema if not exists proto;
create schema if not exists mc;
create schema if not exists net;
comment on schema ref   is 'Generated reference data (Minecraft 26.3, protocol 777). Loaded by tools/load_reports.py.';
comment on schema proto is 'Wire-format codec. Pure functions on bytea.';
comment on schema mc    is 'Game state and rules.';
comment on schema net   is 'Connection queues and protocol state; the gateway only moves bytes in and out of these tables.';
