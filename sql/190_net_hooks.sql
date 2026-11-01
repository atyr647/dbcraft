-- Hooks into the other layers.  The game and world layers REPLACE these functions (create or replace) when they are merged;
-- until then they do nothing, so the connection layer can be tested alone.
--
--   net.hook_join_info(conn)                 -> net.join_info   what to tell a player who enters play (position, game mode, world, health ...)
--   net.hook_on_join(conn)                                       a player is now in the game: create/load the player row (mc.on_join(conn_id, uuid, name))
--   net.hook_player_loaded(conn)                                 the client reported player_loaded
--   net.hook_disconnect(conn)                                    the connection is gone: save and remove the player
--   net.hook_chunks(conn, cx, cz, radius)    -> setof bytea      level_chunk_with_light bodies around (cx, cz), nearest first (mc.chunk_packet)

create or replace function net.hook_join_info(p_conn bigint) returns net.join_info language sql stable as $$
    select net.default_join_info(p_conn) $$;
create or replace function net.hook_on_join(p_conn bigint) returns void language sql as $$ select 1 $$;
create or replace function net.hook_player_loaded(p_conn bigint) returns void language sql as $$ select 1 $$;
create or replace function net.hook_disconnect(p_conn bigint) returns void language sql as $$ select 1 $$;
create or replace function net.hook_chunks(p_conn bigint, p_cx int, p_cz int, p_radius int) returns setof bytea language sql stable as $$
    select null::bytea where false $$;
