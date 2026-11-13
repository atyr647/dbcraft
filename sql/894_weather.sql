-- The weather clock (docs/MINING-AND-COMMANDS.md).  ServerLevel.advanceWeatherCycle and MinecraftServer.setWeatherParameters, read from the 26.3 bytecode and compared with the real
-- server by tests/e2e/weather_probe.py.
--
-- State (mc.game_state): raining / thundering are the WeatherData flags (what the clock is heading for); clear_time, rain_time, thunder_time the counters in ticks; rain_level and
-- thunder_level the 0..1 levels the clients are told, moved by 0.01 per tick towards 1 (flag set) or 0 (flag clear), as `float`s (so 0.06 shows as 0.060000002).  Each tick:
--   * advance_weather on:  clear_time > 0:  it runs down (rain_time and thunder_time are held at 0 if that weather is on, else 1; both flags off);  otherwise each of thunder_time and
--     rain_time runs down and flips its flag when it reaches 0, and a counter that is 0 gets a random length (thunder: 3,600..15,600 ticks while on, 12,000..180,000 off; rain:
--     12,000..24,000 on, 12,000..180,000 off)
--   * the levels move; a changed rain level and a changed thunder level are broadcast (game_event 7 and 8); when `isRaining` (rain level > 0.2) changed, game_event 2 or 1 (stop /
--     start raining) follows with both levels again
-- /weather: clear [duration] = clear_time duration (default 12,000..180,000), both flags off;  rain / thunder [duration] = clear_time 0, rain_time = thunder_time = duration (default
-- 12,000..24,000 / 3,600..15,600), raining (and thundering).  The command itself sends nothing: the clock does.  Not modelled: the weather a player is told when joining while it rains.

alter table mc.game_state add column if not exists clear_time int not null default 0, add column if not exists rain_time int not null default 0, add column if not exists thunder_time int not null default 0,
  add column if not exists rain_level real not null default 0, add column if not exists thunder_level real not null default 0;

-- UniformInt.sample (inclusive)
create or replace function mc.uniform_int(lo int, hi int) returns int language sql volatile as $$ select lo + floor(random() * (hi - lo + 1))::int $$;

-- MinecraftServer.setWeatherParameters(clearTime, weatherTime, raining, thundering)
create or replace function mc.weather_set(p_clear int, p_time int, p_raining boolean, p_thundering boolean) returns void language sql as $$
  update mc.game_state set clear_time = p_clear, rain_time = p_time, thunder_time = p_time, raining = p_raining, thundering = p_thundering $$;

create or replace function mc.weather_tick(cur bigint) returns void language plpgsql as $$
declare g mc.game_state; was boolean; ct int; tt int; rt int; th boolean; rn boolean; nrl real; ntl real; pk bytea := '\x'::bytea; adv boolean := mc.gamerule_bool('advance_weather');
begin
  select * into g from mc.game_state;
  was := g.rain_level::float8 > 0.2;
  ct := g.clear_time; tt := g.thunder_time; rt := g.rain_time; th := g.thundering; rn := g.raining;
  if adv then
    if ct > 0 then
      ct := ct - 1; tt := case when th then 0 else 1 end; rt := case when rn then 0 else 1 end; th := false; rn := false;
    else
      if tt > 0 then tt := tt - 1; if tt = 0 then th := not th; end if;
      elsif th then tt := mc.uniform_int(3600, 15600); else tt := mc.uniform_int(12000, 180000); end if;
      if rt > 0 then rt := rt - 1; if rt = 0 then rn := not rn; end if;
      elsif rn then rt := mc.uniform_int(12000, 24000); else rt := mc.uniform_int(12000, 180000); end if;
    end if;
  end if;
  ntl := least(greatest(case when th then g.thunder_level + 0.01::real else g.thunder_level - 0.01::real end, 0::real), 1::real);
  nrl := least(greatest(case when rn then g.rain_level + 0.01::real else g.rain_level - 0.01::real end, 0::real), 1::real);
  if nrl <> g.rain_level then pk := pk || mc.pkt_game_event(7, nrl); end if;
  if ntl <> g.thunder_level then pk := pk || mc.pkt_game_event(8, ntl); end if;
  if was <> (nrl::float8 > 0.2) then
    pk := pk || mc.pkt_game_event(case when was then 2 else 1 end, 0) || mc.pkt_game_event(7, nrl) || mc.pkt_game_event(8, ntl);
  end if;
  if (ct, tt, rt, th, rn, nrl, ntl) is distinct from (g.clear_time, g.thunder_time, g.rain_time, g.thundering, g.raining, g.rain_level, g.thunder_level) then
    update mc.game_state set clear_time = ct, thunder_time = tt, rain_time = rt, thundering = th, raining = rn, rain_level = nrl, thunder_level = ntl;
  end if;
  if pk <> '\x'::bytea then insert into mc.play_out (conn_id, data) select conn_id, pk from mc.player where conn_id is not null order by entity_id; end if;
end $$;
