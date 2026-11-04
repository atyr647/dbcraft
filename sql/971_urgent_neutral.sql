-- Chat from real clients (docs/PERF-IDLE2.md): which serverbound play packets may stand ahead of a chat frame of the same connection without keeping the urgent lane (sql/801) from
-- handling that chat between ticks.
--
--   net.urgent_neutral_play_ids()   the protocol ids (ref.packet) of the kinds the gateway treats as neutral.  A chat frame is taken by the lane when no frame ahead of it (any connection)
--                                   is a command, and every frame ahead of it from its own connection is a chat, or one of these kinds (the gateway adds client_tick_end and the four
--                                   movement kinds itself: they were neutral in the first version of the lane).  Everything else keeps the old rule: that connection's chat waits for the tick.
--
-- What "neutral" has to mean: the lane runs mc.apply_chat BEFORE the rest of the window's frames, the tick runs it AFTER them (moves, misc input, ...), so a kind is neutral exactly when
-- what the tick does with it neither reads nor writes anything mc.apply_chat reads or writes (the sender's mc.player row's name and uuid, its chat_sent counter, every recipient's chat_recv
-- counter and connection, mc.chat_log, the recipients' output queue) -- and when the real server's handler does not either.  Both halves are checked, not assumed:
--   * the vanilla half, from the 26.3 jar (javap -c -p on ServerGamePacketListenerImpl, `tools/jar_handlers.py`): of the 61 serverbound play handlers of ServerGamePacketListenerImpl (51 queue their body on the main thread with PacketUtils.ensureRunningOnSameThread, 10 run on the network thread) only handleChat,
--     handleChatCommand, handleSignedChatCommand, handleChatAck and handleChatSessionUpdate touch the chat machinery (the signed chain's last-seen validator, the chat session, the
--     message chain); handleClientInformation changes the player's options, which include the chat visibility that tryHandleChat reads on the network thread (dbcraft has no chat
--     visibility: neither path implements "hidden" chat); handleSetCommandBlock/Minecart/StructureBlock only send their own error message to their own sender.  tryHandleChat runs on the
--     network thread (illegal characters, hidden chat) and queues the message itself on the main thread with MinecraftServer.execute, so in vanilla a chat is already taken in arrival
--     order with the other main-thread work (every handler except chat, custom_payload, ping_request, sign_update, edit_book, command suggestions and configuration_acknowledged
--     is queued the same way): there is no ordering between a chat and a neighbour that does not touch chat state to preserve.
--   * the dbcraft half: tests/sql/971_urgent_neutral.sql sends every kind in this list (with an empty body, a short body and a body of the right shape where the tick parses one) ahead
--     of a chat, once through the tick and once through the lane, and compares the players' state and every connection's frames.  It does so with the classic broadcast, with the player-visibility tracker (first
--     synchronisation, settled, asleep, players waiting for a teleport) and with players at an open chest, so that a kind a later module reacts to (a tracker, a container) fails there.
--
-- What is NOT in the list, on purpose: the commands (a barrier for every connection), chat_ack and chat_session_update (chat protocol), command_suggestion, the commands in disguise
-- (change_game_mode, change_difficulty, lock_difficulty, set_game_rule), edit_book / sign_update / the block-entity editors (text input), configuration_acknowledged (a state change), and the
-- entity interaction kinds (attack, interact, entity_tag_query, teleport_to_entity, spectator_action, move_vehicle, paddle_boat, pick_item_from_entity, select_trade, set_beacon): dbcraft
-- ignores them today, and the modules that will give them effects (entities, containers) should decide, with the paired test, whether a chat may overtake them.

create or replace function net.urgent_neutral_play_ids() returns int[] language sql stable as $$
    select coalesce(array_agg(protocol_id order by protocol_id), '{}') from ref.packet
     where state = 'play' and direction = 'serverbound'
       and name in ('minecraft:accept_teleportation', 'minecraft:chunk_batch_received', 'minecraft:client_command', 'minecraft:client_information', 'minecraft:client_tick_end',
                    'minecraft:container_button_click', 'minecraft:container_click', 'minecraft:container_close', 'minecraft:container_slot_state_changed', 'minecraft:cookie_response',
                    'minecraft:custom_payload', 'minecraft:debug_subscription_request', 'minecraft:keep_alive', 'minecraft:move_player_pos', 'minecraft:move_player_pos_rot',
                    'minecraft:move_player_rot', 'minecraft:move_player_status_only', 'minecraft:pick_item_from_block', 'minecraft:ping_request', 'minecraft:place_recipe',
                    'minecraft:player_abilities', 'minecraft:player_action', 'minecraft:player_command', 'minecraft:player_input', 'minecraft:player_loaded', 'minecraft:pong',
                    'minecraft:punch', 'minecraft:recipe_book_change_settings', 'minecraft:recipe_book_seen_recipe', 'minecraft:rename_item', 'minecraft:resource_pack',
                    'minecraft:seen_advancements', 'minecraft:set_carried_item', 'minecraft:set_creative_mode_slot', 'minecraft:use_item', 'minecraft:use_item_on') $$;
