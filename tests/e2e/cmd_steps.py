"""The scripted session shared by tests/e2e/cmd_probe.py (records) and tests/e2e/compare_commands.py (compares).
PLAYERS join in this order: Op4 is an operator with level 4, Bob and Cy are plain players (level 0), Op2 has level 2 (see tests/e2e/cmd_vanilla.sh for how
the vanilla server is given its ops; dbcraft is told with mc.op).  A step is (player, command) or (player, "!chat", text) / ("!join"/"!leave").
"""
PLAYERS = ["Op4", "Bob", "Cy", "Op2"]
STEPS = [
    ("Op4", "list"), ("Bob", "list"),
    ("Op4", "seed"), ("Bob", "seed"),
    ("Op4", "me waves"), ("Bob", "me is here"), ("Op4", "me"),
    ("Op4", "msg Bob hello there"), ("Bob", "tell Op4 hi back"), ("Cy", "w Bob psst"),
    ("Op4", "msg Nobody hi"), ("Op4", "msg Bob"), ("Op4", "msg"),
    ("Op4", "msg @a all of you"), ("Op4", "msg @p near"), ("Op4", "msg @s myself"),
    ("Op4", "say hello"), ("Bob", "say nope"), ("Op4", "say @a hi"), ("Op4", "say"),
    ("Op4", "help"), ("Bob", "help"), ("Op4", "help gamemode"), ("Op4", "help tp"), ("Op4", "help nosuch"), ("Bob", "help gamemode"), ("Op4", "help msg"),
    ("Op4", "gamerule keepInventory"), ("Op4", "gamerule keep_inventory"), ("Op4", "gamerule keep_inventory true"), ("Op4", "gamerule keep_inventory true"),
    ("Op4", "gamerule keep_inventory false"),
    ("Op4", "clear Bob"), ("Op4", "clear Bob minecraft:stone"), ("Op4", "give Bob minecraft:stone 5"), ("Op4", "clear Bob minecraft:stone 0"),
    ("Op4", "clear Bob minecraft:stone 2"), ("Op4", "clear Bob"), ("Op4", "clear @a"),
    ("Op4", "gamemode survival @a"), ("Op4", "gamemode creative @s"), ("Op4", "gamemode creative @a[name=Bob]"), ("Op4", "gamemode adventure @e[type=player,limit=1]"),
    ("Op4", "gamemode survival @a[gamemode=creative]"), ("Op4", "gamemode creative @a"), ("Op4", "gamemode creative @r"),
    ("Op4", "tp @s 5 -60 5"), ("Op4", "tp Cy @s"), ("Op4", "tp @a[name=Bob] Cy"), ("Op4", "tp @p Bob"),
    ("Op4", "give @a minecraft:dirt 2"), ("Op4", "give @s minecraft:stone"), ("Op4", "give @a[name=!Bob] minecraft:apple 3"),
    ("Op4", "msg @a[name=Bob] selected"), ("Op4", "msg @a[distance=..3] near ones"), ("Op4", "msg @a[limit=1,sort=nearest] first"),
    ("Op4", "msg @a[limit=2,sort=furthest] last"), ("Op4", "msg @e[type=player,name=Cy] cy only"), ("Op4", "msg @a[nonsense=1] x"), ("Op4", "msg @a[ x"),
    ("Op4", "msg @x hi"), ("Op4", "msg @a[gamemode=survival] surv"), ("Op4", "msg @a[gamemode=!creative] notcreative"),
    ("Op4", "kill @a[name=nosuch]"), ("Op4", "kill nosuch"),
    ("Op4", "op Bob"), ("Op4", "deop Bob"),
    ("Op4", "op Op2"), ("Op4", "deop Op2"),
    ("Op4", "nosuchcommand"), ("Bob", "fill 0 0 0 1 1 1 stone"), ("Op4", "gamemode"), ("Op4", "gamemode foo"), ("Op4", "tp"), ("Op4", "give"),
    ("Op4", "time"), ("Op4", "time set"), ("Op4", "weather"),
]
