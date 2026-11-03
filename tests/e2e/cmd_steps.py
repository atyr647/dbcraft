"""The scripted session shared by tests/e2e/cmd_probe.py (records) and tests/e2e/compare_commands.py (compares).

PLAYERS join in this order.  Op1 .. Op4 are operators of level 1 .. 4 (the vanilla server is given them by tests/e2e/cmd_vanilla.sh, dbcraft by
tests/e2e/cmd_ops.py), Bob and Cy are plain players.  A step is (player, "command") or (player, "!chat", text) / (player, "!send", packet name, body).
Every block starts from the same state (everybody creative at 0.5 -60 0.5) so that positions and inventories agree on both servers.

MASK: step text -> what may differ.  "shape" = only the kinds of packets must agree (values of the run: the clock).
NEEDS_SURVIVAL: steps whose effect belongs to the survival module (death); they are compared only with --survival.
"""
import mcclient as m

PLAYERS = ["Op4", "Bob", "Cy", "Op1", "Op2", "Op3"]
RESET = [("Op4", "gamemode creative @a"), ("Op4", "tp @a 0.5 -60 0.5"), ("Op4", "clear @a")]

MASK = {"time add 20": "shape", "time add 1d": "shape", "time query time": "shape", "time query gametime": "shape"}
UNSUPPORTED = ("give Bob stone[x=1]",)       # item components: dbcraft says it does not support them (tests/sql/811)
NEEDS_SURVIVAL = ("kill Bob", "kill @e[type=player,name=Bob,limit=1]", "kill @s", "client_command", "kill Op4")

STEPS = (
    [("Op4", "tp @a 0.5 -60 0.5")]
    # ---- information commands, permission levels
    + [("Op4", "list"), ("Bob", "list"), ("Op4", "list uuids"), ("Op4", "list foo"), ("Op4", "list "),
       ("Op4", "seed"), ("Bob", "seed"), ("Op1", "seed"), ("Op2", "seed"), ("Op4", "seed extra"),
       ("Op4", "help"), ("Bob", "help"), ("Op1", "help"), ("Op2", "help"), ("Op3", "help"),
       ("Op4", "help gamemode"), ("Op4", "help tp"), ("Op4", "help nosuch"), ("Bob", "help gamemode"), ("Op4", "help msg"), ("Op4", "help gamemode creative"),
       ("Op4", "help gamemode creative Bob"), ("Op4", "help give"), ("Op4", "help time set"), ("Op4", "help weather"), ("Op4", "help list"), ("Op4", "help xp"), ("Op4", "help 1"),
       ("Op4", "help gamerule"), ("Op4", "help teleport")]
    # ---- chat commands
    + [("Op4", "me waves"), ("Bob", "me is here"), ("Op4", "me"), ("Op4", "me  leading"), ("Op4", "me @s"), ("Op4", "me @a waves"), ("Bob", "me @a hi"),
       ("Op4", "msg Bob hello there"), ("Bob", "tell Op4 hi back"), ("Cy", "w Bob psst"), ("Op4", "msg Nobody hi"), ("Op4", "msg Bob"), ("Op4", "msg"),
       ("Op4", "msg @a all of you"), ("Op4", "msg @p near"), ("Op4", "msg @s myself"), ("Op4", "msg Bob  two spaces"), ("Op4", "msg Op4 to myself"),
       ("Op4", "say hello"), ("Bob", "say nope"), ("Op4", "say @a hi"), ("Op4", "say"), ("Op4", "say  x"), ("Op4", "say a b  c"), ("Op4", "say @s"),
       ("Op4", "say @e[type=player] y"), ("Op4", "say @a[name=zzz] x"), ("Op4", "say a @a[name=zzz] b"), ("Op4", "me @e[type=zombie] x"), ("Op4", "say @x hello"),
       ("Op4", "say @ hello"), ("Bob", "msg @a x"), ("Bob", "msg Cy ok"), ("Bob", "msg @p x"), ("Bob", "say @a"), ("Bob", "msg @s x"), ("Bob", "msg @e x"),
       ("Bob", "!chat", "hello world")]
    # ---- selectors in /msg: options, errors
    + [("Op4", "msg @a[name=Bob] selected"), ("Op4", "msg @a[distance=..3] near ones"), ("Op4", "msg @a[limit=1,sort=nearest] first"), ("Op4", "msg @a[limit=2,sort=furthest] last"),
       ("Op4", "msg @e[type=player,name=Cy] cy only"), ("Op4", "msg @a[nonsense=1] x"), ("Op4", "msg @a[ x"), ("Op4", "msg @x hi"), ("Op4", "msg @a[gamemode=survival] surv"),
       ("Op4", "msg @a[gamemode=!creative] notcreative"), ("Op4", "msg @a[limit=0] x"), ("Op4", "msg @a[limit=-1] x"), ("Op4", "msg @a[limit=x] x"), ("Op4", "msg @a[sort=foo] x"),
       ("Op4", "msg @a[distance=x] x"), ("Op4", "msg @a[distance=..] x"), ("Op4", "msg @a[distance=5..1] x"), ("Op4", "msg @a[gamemode=foo] x"), ("Op4", "msg @a[type=zombie] x"),
       ("Op4", "msg @a[type=player] x"), ("Op4", "msg @a[type=!player] x"), ("Op4", "msg @e[type=zombie] x"), ("Op4", "msg @a[name=Bob,name=Cy] x"), ("Op4", "msg @a[name=Bob,name=!Cy] x"),
       ("Op4", "msg @a[limit=1,limit=2] x"), ("Op4", "msg @s[limit=1] x"), ("Op4", "msg @p[limit=2] x"), ("Op4", "msg @a[] x"), ("Op4", "msg @a[name=Bob,] x"), ("Op4", "msg @a[name=] x"),
       ("Op4", "msg @a[name Bob] x"), ("Op4", "msg @a[name=Bob x"), ("Op4", "msg @a[name=Bob]x"), ("Op4", "msg @ x"), ("Op4", "msg @e x"), ("Op4", "msg @a[x=0,y=-60,z=0,distance=..1] x"),
       ("Op4", "msg @a[level=0..] x"), ("Op4", "msg @a[level=5] x"), ("Op4", "msg @a[tag=foo] x"), ("Op4", "msg @a[team=foo] x"), ("Op4", "msg @a[dx=1] x"), ("Op4", "msg @a[sort=arbitrary] x"),
       ("Op4", "msg @a[sort=nearest,limit=1] x"), ("Op4", "msg 00000000-0000-0000-0000-000000000001 x"), ("Op4", "msg faa5dca3-c3d4-354b-ae1b-dde9e5a14b3b x"),
       ("Op4", "msg @a[type=!foo] x"), ("Op4", "msg @a[gamemode=!foo] x"), ("Op4", "msg @a[type=#minecraft:skeletons] x"), ("Op4", "msg @a[type=minecraft:player,type=player] x"),
       ("Op4", "msg @a[distance=-1] x"), ("Op4", "msg @a[distance=..-1] x"), ("Op4", "msg @a[level=-1] x"), ("Op4", "msg @a[level=1.5] x"), ("Op4", "msg @a[ name = Bob ] x"),
       ("Op4", "msg @a[name=\"Bob\"] x"), ("Op4", "msg @a[name='Bob'] x"), ("Op4", "msg @a[name=\"Bob] x"), ("Op4", "msg @a[x=1.5] x"), ("Op4", "msg @n x"), ("Op4", "msg @n[limit=2] x")]
    # ---- game rules
    + [("Op4", "gamerule keepInventory"), ("Op4", "gamerule keep_inventory"), ("Op4", "gamerule keep_inventory true"), ("Op4", "gamerule keep_inventory true"),
       ("Op4", "gamerule keep_inventory false"), ("Op4", "gamerule pvp"), ("Op4", "gamerule pvp false"), ("Op4", "gamerule pvp xyz"), ("Op4", "gamerule pvp true"),
       ("Op4", "gamerule random_tick_speed"), ("Op4", "gamerule random_tick_speed 5"), ("Op4", "gamerule random_tick_speed -1"), ("Op4", "gamerule random_tick_speed x"),
       ("Op4", "gamerule random_tick_speed 3"), ("Op4", "gamerule minecraft:pvp"), ("Op4", "gamerule nosuchrule"), ("Op4", "gamerule"),
       ("Op4", "gamerule fire_spread_radius_around_player -1"), ("Op4", "gamerule fire_spread_radius_around_player -2"), ("Op4", "gamerule fire_spread_radius_around_player 128"),
       ("Op4", "gamerule minecraft:keep_inventory true"), ("Op4", "gamerule minecraft:keep_inventory"), ("Op4", "gamerule keep_inventory false"),
       ("Op4", "gamerule reduced_debug_info true"), ("Op4", "gamerule reduced_debug_info false"), ("Op4", "gamerule immediate_respawn true"), ("Op4", "gamerule immediate_respawn false"),
       ("Op4", "gamerule limited_crafting true"), ("Op4", "gamerule limited_crafting false"), ("Op3", "gamerule pvp false"), ("Op3", "gamerule pvp true"),
       ("Op4", "gamerule send_command_feedback false"), ("Op4", "gamerule keep_inventory true"), ("Op4", "gamerule send_command_feedback true"), ("Op4", "gamerule keep_inventory false")]
    # every rule's default value
    + [("Op4", "gamerule " + r) for r in (
        "advance_time advance_weather allow_entering_nether_using_portals block_drops block_explosion_drop_decay command_block_output command_blocks_work drowning_damage "
        "elytra_movement_check ender_pearls_vanish_on_death entity_drops fall_damage fire_damage fire_spread_radius_around_player forgive_dead_players freeze_damage "
        "global_sound_events immediate_respawn keep_inventory lava_source_conversion limited_crafting locator_bar log_admin_commands max_block_modifications max_command_forks "
        "max_command_sequence_length max_entity_cramming max_snow_accumulation_height mob_drops mob_explosion_drop_decay mob_griefing natural_health_regeneration "
        "player_movement_check players_nether_portal_creative_delay players_nether_portal_default_delay players_sleeping_percentage projectiles_can_break_blocks pvp raids "
        "random_tick_speed reduced_debug_info respawn_radius send_command_feedback show_advancement_messages show_death_messages spawn_mobs spawn_monsters spawn_patrols "
        "spawn_phantoms spawn_wandering_traders spawn_wardens spawner_blocks_work spectators_generate_chunks spread_vines tnt_explodes tnt_explosion_drop_decay universal_anger "
        "water_source_conversion").split()]
    # ---- inventory: clear, give
    + RESET
    + [("Op4", "clear Bob"), ("Op4", "clear Bob minecraft:stone"), ("Op4", "give Bob minecraft:stone 5"), ("Op4", "clear Bob minecraft:stone 0"), ("Op4", "clear Bob minecraft:stone 2"),
       ("Op4", "clear Bob"), ("Op4", "clear @a"), ("Op4", "clear Nobody"), ("Op4", "clear Bob foo"), ("Op4", "clear Bob minecraft:stone -1"), ("Op4", "clear Bob minecraft:stone x"),
       ("Op4", "give Bob"), ("Op4", "give Bob foo"), ("Op4", "give Bob minecraft:foo"), ("Op4", "give Bob stone x"), ("Op4", "give Bob stone 0"), ("Op4", "give Bob stone 5 extra"),
       ("Op4", "give Bob stone 99999"), ("Op4", "give Bob stone[x=1]"), ("Op4", "give Nobody stone"), ("Op4", "give Bob STONE"), ("Op4", "give Bob minecraft:dirt 1 "),
       ("Op4", "give @a minecraft:dirt 2"), ("Op4", "give @s minecraft:stone"), ("Op4", "give @a[name=!Bob] minecraft:apple 3"), ("Op4", "give @a[limit=1] minecraft:dirt"),
       ("Op4", "give @e[type=player,name=Bob] minecraft:dirt"), ("Op4", "give @r[name=Bob] minecraft:dirt"), ("Op4", "give @a[name=nosuch] minecraft:dirt"),
       ("Op4", "give Bob minecraft:dirt 70"), ("Op4", "clear Bob minecraft:dirt 10"), ("Op4", "clear Bob minecraft:dirt"), ("Op4", "clear @a[name=Bob]"), ("Op4", "clear @s"), ("Op4", "clear @r[name=Bob]"),
       ("Op4", "clear @a")]
    # ---- game mode
    + RESET
    + [("Op4", "gamemode survival @a"), ("Op4", "gamemode creative @s"), ("Op4", "gamemode creative @a[name=Bob]"), ("Op4", "gamemode adventure @e[type=player,limit=1]"),
       ("Op4", "gamemode survival @a[gamemode=creative]"), ("Op4", "gamemode creative @a"), ("Op4", "gamemode creative Nobody"), ("Op4", "gamemode creative Op4"), ("Op4", "gamemode 1"),
       ("Op4", "gamemode CREATIVE"), ("Op4", "gamemode survival Bob extra"), ("Op4", "gamemode spectator"), ("Op4", "gamemode creative"), ("Op4", "gamemode"), ("Op4", "gamemode foo"),
       ("Op4", "gamemode creative @a[gamemode=creative]"), ("Op4", "gamemode survival @a[gamemode=!survival]"), ("Op4", "gamemode creative @a[gamemode=survival]"),
       ("Op4", "gamemode creative @a[gamemode=adventure]"), ("Op4", "gamemode creative @a[gamemode=spectator]"), ("Op4", "gamemode creative @n"), ("Op1", "gamemode creative")]
    # ---- teleport
    + RESET
    + [("Op4", "tp @s 5 -60 5"), ("Op4", "tp Cy @s"), ("Op4", "tp @a[name=Bob] Cy"), ("Op4", "tp @p Bob"), ("Op4", "tp 1 2"), ("Op4", "tp Bob 1 2 3"), ("Op4", "tp ~ ~ ~"),
       ("Op4", "tp Bob Nobody"), ("Op4", "tp 1 2 x"), ("Op4", "tp ~1 ~ ~-1"), ("Op4", "tp 0.5 -60 0.5"), ("Op4", "tp Bob 0.5 -60 0.5 90 0"), ("Op4", "tp Bob 1 2"), ("Op4", "tp Op4 Cy"),
       ("Op4", "tp"), ("Op4", "tp @e[type=player,limit=1] Bob"), ("Op4", "tp @a[limit=2] Bob"), ("Op4", "tp Bob @a"), ("Op4", "tp Bob @a[limit=1]"), ("Op4", "tp Bob @p"), ("Op4", "tp @p"),
       ("Op4", "tp ~ -60 ~"), ("Op4", "tp ~1 -60 0.5"), ("Op4", "tp 0.5 ~ 0.5"), ("Op4", "tp Bob ~ ~ ~ ~ ~"), ("Op4", "tp Bob ~ ~ ~ 45 ~"), ("Op4", "tp Bob 3 -60 3 0 0"), ("Op4", "tp Bob ~ ~ ~"),
       ("Op4", "tp @a ~1 ~ ~"), ("Op4", "tp @a 0.5 -60 0.5"), ("Op4", "tp @a Op4"), ("Op4", "tp Bob Cy"), ("Op4", "tp Bob 10 -60 10"), ("Op4", "tp ^ ^ ^1")]
    # ---- time, weather, difficulty
    + RESET
    + [("Op4", "time set 100"), ("Op4", "time set day"), ("Op4", "time set noon"), ("Op4", "time add 20"), ("Op4", "time set -5"), ("Op4", "time set 1d"), ("Op4", "time set 5x"),
       ("Op4", "time query daytime"), ("Op4", "time query gametime"), ("Op4", "time query time"), ("Op4", "time set midnight"), ("Op4", "time set night"), ("Op4", "time add 1d"),
       ("Op4", "time"), ("Op4", "time set"), ("Op4", "weather"), ("Op4", "weather clear 100"), ("Op4", "weather clear"),
       ("Op4", "difficulty"), ("Op4", "difficulty hard"), ("Op4", "difficulty peaceful"), ("Op4", "difficulty peaceful"), ("Op4", "difficulty xyz")]
    # ---- operators, whitelist, bans
    + [("Op4", "op Bob"), ("Op4", "deop Bob"), ("Op4", "op Op2"), ("Op4", "deop Op2"), ("Op4", "op Bob extra"), ("Op4", "op"), ("Op4", "deop Bob"),
       ("Op3", "ban"), ("Op3", "stop"), ("Op2", "ban Bob"), ("Op2", "stop"), ("Op2", "op Bob"), ("Op4", "deop Op1"), ("Op4", "op Op1"),
       ("Op4", "whitelist"), ("Op4", "whitelist list"), ("Op4", "whitelist add Bob"), ("Op4", "whitelist add Bob"), ("Op4", "whitelist list"), ("Op4", "whitelist remove Bob"),
       ("Op4", "whitelist remove Bob"), ("Op4", "whitelist on"), ("Op4", "whitelist on"), ("Op4", "whitelist off"), ("Op4", "whitelist off"), ("Op4", "whitelist reload"),
       ("Op4", "ban Cy being rude"), ("Op4", "ban Cy"), ("Op4", "pardon Cy"), ("Op4", "pardon Cy"),
       ("Op4", "nosuchcommand"), ("Bob", "fill 0 0 0 1 1 1 stone")]
    # ---- death (the survival module)
    + RESET
    + [("Op4", "kill nosuch"), ("Op4", "kill @a[name=nosuch]"), ("Op4", "kill Op4 Op4"),
       ("Op4", "gamemode survival Bob"), ("Op4", "kill Bob"), ("Bob", "!send", "minecraft:client_command", m.varint(0)),
       ("Op4", "kill @e[type=player,name=Bob,limit=1]"), ("Bob", "!send", "minecraft:client_command", m.varint(0))]
)
