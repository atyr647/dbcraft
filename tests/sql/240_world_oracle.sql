-- ORACLE TEST: regenerate every captured vanilla level_chunk_with_light packet from rows and compare the bytes.
-- Needs the capture written by tools/capture_vanilla.py (outside git).  Skips, loudly, when it is missing.
\! python3 tools/load_world_ref.py
select count(*) > 0 as have_biomes from mc.biome \gset
create temp table cap (cx int, cz int, framed text);
\copy cap from program 'python3 tools/extract_chunk_fixture.py'
select (select count(*) from cap) > 0 and :'have_biomes'::boolean as have_capture \gset

\if :have_capture
  select t.is_true('capture has chunks', (select count(*) from cap) >= 25);
  select t.eq('biome ids are the alphabetical rank of the key', (select count(*) from mc.biome b where b.id <> (select count(*) from mc.biome o where o.name < b.name))::int, 0);
  select t.eq('plains is biome 41', mc.biome_id('minecraft:plains'), 41);
  select t.eq('chunk packet id is 46 (0x2e)', mc.chunk_packet_id(), 46);

  -- Regenerate each chunk and compare.  Vanilla sends light layer 0 two ways (an "empty" bit, or a present all-zero array, a transient of its
  -- light engine on the first chunks of a session); both mean the same light, so each chunk must match in one of the two forms.
  create function pg_temp.verdict(p_cx int, p_cz int, p_framed text) returns text language plpgsql as $f$
  begin
      perform mc.generate_flat('minecraft:overworld', p_cx, p_cz, true);
      perform mc.ensure_chunk_current('minecraft:overworld', p_cx, p_cz);
      if encode(proto.frame(mc.chunk_packet_id(), mc.chunk_packet_body('minecraft:overworld', p_cx, p_cz)), 'hex') = p_framed then return 'exact'; end if;
      perform mc.compute_light('minecraft:overworld', p_cx, p_cz, true);
      if encode(proto.frame(mc.chunk_packet_id(), mc.chunk_packet_body('minecraft:overworld', p_cx, p_cz)), 'hex') = p_framed then return 'sky0-as-data'; end if;
      return 'MISMATCH';
  end $f$;
  create temp table verdicts as select cx, cz, pg_temp.verdict(cx, cz, framed) v from cap;
  select t.eq('no captured chunk differs', (select count(*) from verdicts where v = 'MISMATCH')::int, 0);
  select t.is_true('most chunks match with the steady-state light form', (select count(*) from verdicts where v = 'exact') >= (select count(*) from verdicts) - 5);
  do $d$ begin
      raise notice 'oracle: % chunks byte-identical (% steady-state form, % with light layer 0 as a zero array)',
          (select count(*) from verdicts), (select count(*) from verdicts where v = 'exact'), (select count(*) from verdicts where v = 'sky0-as-data');
  end $d$;

  -- the cached path returns the same bytes as the uncached one
  select t.eq('mc.chunk_packet (cached) equals the capture for an exact chunk',
              (select encode(mc.chunk_packet('minecraft:overworld', v.cx, v.cz), 'hex') from verdicts v where v.v = 'exact' limit 1),
              (select c.framed from cap c join verdicts v using (cx, cz) where v.v = 'exact' limit 1));
\else
  do $d$ begin raise notice 'SKIPPED oracle test: no capture found (run the vanilla server and tools/capture_vanilla.py)'; end $d$;
\endif
