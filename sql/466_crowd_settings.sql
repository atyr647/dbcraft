-- Entity update interval of players (sql/431, 434, 382): vanilla's EntityType.PLAYER is updateInterval(2), so ServerEntity.sendChanges broadcasts a moving player's position
-- and rotation every second tick (one packet per 2 ticks, `ticks` = 2 and the combined delta), not every tick.  Read from the class bytecode and confirmed against
-- recorded vanilla traffic (tests/bench/crowd/rates.py: 10.25 packets/s for a walker, against 19/s from dbcraft before this setting).  1 = send every tick (the old behaviour).
insert into mc.server_property (key, value, default_value, note)
values ('dbcraft.player-update-interval', '2', '2', 'dbcraft: ticks between position/rotation broadcasts of a moving player; vanilla EntityType.PLAYER.updateInterval = 2; 1 = every tick')
on conflict (key) do nothing;
