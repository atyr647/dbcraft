# World storage and chunk encoding

Everything lives in `sql/200_world.sql` … `sql/240_world_flat.sql`.  World data is stored **in the Minecraft wire format** (palette + packed longs), so sending a
chunk never re-packs anything.  Targets Java Edition 26.3 (protocol 777).  Tests: `tests/sql/200_*`, `210_*`, `240_*`, `250_*`.  Benchmarks: `tests/bench/world/`.

## What is verified against real vanilla, and what is not

**Byte-for-byte against captured vanilla 26.3 packets** (a real server was run and recorded with `tools/capture_vanilla.py`):

| Check | Result |
|---|---|
| Flat world: regenerate every captured `level_chunk_with_light` from rows (`tests/sql/240_world_oracle.sql`) | **49 of 49 identical** (46 in the steady-state light form, 3 in vanilla's transient form, see below) |
| Real terrain: load captured chunks as rows and re-encode (`tests/sql/250_world_terrain_oracle.sql`) | **49 of 49 identical**: 1,176 sections, 558 palette sections (block palettes of 4, 5, 6 and 7 bits; biome palettes of 1 and 2 bits; 618 single-value sections), 13 block entities |
| `block_count` and `fluid_count` of every captured section vs. our name-based classification (`mc.is_air`, `mc.has_fluid`) | all 1,176 sections agree (fluid sections are present, so this is not vacuous) |
| WORLD_SURFACE heightmap recomputed from the loaded sections | **0 of 12,544 columns differ** |
| An independent decoder (written in the test, not the encoder) reading our wire bytes back | matches the stored blocks for single, 4-bit and global-palette sections |

**Structurally right but not checked against vanilla** (no captured sample exercises it):

* Block containers with a **global palette** (more than 256 distinct states in one section; 16 bits per entry, no palette list).  The layout follows the 26.3 class
  (`Data.write`) and round-trips through our own decoder, but no vanilla chunk in the capture had one.
* Biome containers of 3 bits, and the global biome palette (7 bits).
* `fluid_count` for blocks the capture did not contain (the classification is name-based: water, lava, bubble column, kelp, seagrass, `waterlogged=true`).
* Anything about light other than a flat world and straight-down terrain (see "Light").

**Known differences from vanilla:**

* **Heightmap entry order.**  Vanilla writes the three heightmaps in `HashMap` order, which changes between JVM runs (the flat capture has 4, 5, 1; the terrain capture has
  5, 1, 4).  We always write MOTION_BLOCKING (4), MOTION_BLOCKING_NO_LEAVES (5), WORLD_SURFACE (1).  Clients accept any order; the terrain test reorders the
  captured entries before comparing.
* **Light layer 0.**  Vanilla sends the layer below the world either as an "empty" bit or as a present all-zero array (a transient of its light engine: it happened on 3
  of the first 49 chunks of a session).  Both mean the same light.  `mc.compute_light(…, p_sky0_as_data := true)` reproduces the second form; the oracle test checks that
  every captured chunk matches in one of the two forms.
* **Block entity order** is insertion order (`mc.block_entity.seq`); vanilla's is a hash-map order.

## What is approximated (measured against vanilla)

* **MOTION_BLOCKING / MOTION_BLOCKING_NO_LEAVES.**  The generator reports carry no collision data, so "blocks motion" is a name list (`mc.non_collidable`).  On the pale-garden
  terrain capture: **17 of 12,544 columns differ for MOTION_BLOCKING and 31 for NO_LEAVES** (0.14% and 0.25%).  The list was extended after the first test run showed vanilla
  excludes `pale_hanging_moss`, `pale_moss_carpet` and `leaf_litter`; the other additions (marked "NOT verified" in the SQL) are my judgement.  The sample is mostly one region (a pale garden), so other biomes' blocks are untested.
* **Sky light** is a straight-down model: 15 above the highest non-air block of a column, 0 at and below it, no horizontal spread, no attenuation by water or leaves, no
  cross-chunk effects.  Exact for flat worlds (that is what the oracle checks).  On real terrain **517 of 682 captured sky layers (76%) are identical**; the rest differ
  because vanilla spreads light sideways under overhangs.  Informational: the terrain test prints it and does not assert it.
* **Block light** is not modelled: every layer is all zero (no torch or lava propagation).

## Layout facts learned from the 26.3 classes (they differ from older versions)

* A section is `short block_count, short fluid_count, blocks container, biomes container` (the fluid count is new).
* A paletted container is `u8 bits`, then the palette (single value: one VarInt; linear/hashed: VarInt size + VarInt ids; global: nothing), then the packed longs with
  **no length prefix**.  Blocks: one palette entry is a single value (0 bits); 2 to 16 entries use 4 bits, 17 to 32 use 5, 33 to 64 use 6, 65 to 128 use 7,
  129 to 256 use 8; beyond 256 entries the global palette (16 bits, no palette list).  Biomes: one entry is single (0 bits); 2 entries 1 bit, 3 to 4 entries 2 bits,
  5 to 8 entries 3 bits; beyond 8 entries the global palette (7 bits).
* Entries are packed `floor(64 / bits)` per long, least significant first, no entry spans two longs, each long written big-endian.
* Block index inside a section: `(y & 15) << 8 | (z & 15) << 4 | (x & 15)`.  Heightmaps: 9 bits per column at height 384, index `x + 16 * z`, value `(top y + 1) - min_y`.
* Light data: four bit sets (sky, block, empty sky, empty block), each as a VarInt byte count and little-endian bytes (not long arrays), then the sky arrays, then the block arrays.
  Layers: index 0 is below the world; arrays are sent for layers up to the first section above the highest non-empty one.
* `accept_teleportation` (not part of this worker) is now `id, x, y, z, yRot, xRot`.

## Block change packets (`block_update`, `section_blocks_update`)

Everything a client is told about changed blocks goes through `mc.broadcast_block_events` (sql/432, the tick's step 5) from the rows in `mc.block_event`.  The rules were read
with `javap -c -p` from the pinned 26.3 server (`ChunkHolder.blockChanged` / `broadcastChanges`, `ClientboundSectionBlocksUpdatePacket`, `SectionPos`, and fastutil
8.5.18's `ShortOpenHashSet` / `HashCommon`) and then compared with a real vanilla server (below).  What vanilla does:

* `ChunkHolder.blockChanged(pos)` adds the 12-bit section-relative index `x << 8 | z << 4 | y` (note: not the storage index, which is `y << 8 | z << 4 | x`) to a
  `ShortOpenHashSet` per section, when a block really changed (setting the same state does not get that far).  A position that changes and changes back **stays** in the set.
* At the end of the tick, per section in ascending section order: **one** position in the set gives `ClientboundBlockUpdatePacket(pos, the state it has now)`; **two or more**
  give one `ClientboundSectionBlocksUpdatePacket`.  There is no larger threshold: a whole section of 4,096 changed positions is one packet (16,394 bytes for stone).  (The
  64 in `broadcastChanges` is the *light* update's re-send threshold; it does not apply to blocks.)
* The packet is: the `SectionPos` as one long (`(x & 0x3FFFFF) << 42 | (y & 0xFFFFF) | (z & 0x3FFFFF) << 20`), a VarInt count, then per position a VarLong
  `state id << 12 | index`, **in the iteration order of the set**.  That order is the open-addressing layout of fastutil's `ShortOpenHashSet` (initial table 32, load factor
  0.75, `mix(k) = k * 0x9E3779B9; h ^ (h >>> 16)`, linear probing, doubling rehash that re-inserts the old table from its last slot down; key 0 is held outside the table and
  comes first; iteration walks the table downwards).  It is a deterministic function of the order of insertion, and `mc.shortset_order` (sql/850) reproduces it exactly.
* The `/fill` command inserts in the order x fastest, then y, then z (confirmed by the real server's packets below); a function of `/setblock` commands inserts in command order.

How dbcraft produces the same bytes:

* **Events.**  `mc.set_block` / `mc.set_blocks` / `mc.edit_section` queue one `kind = 'block'` row per changed block (old and new state).  `mc.fill` queues ONE
  `kind = 'cells'` row per section it changed: the section corner and a 512-byte bit map of the changed positions (`mc.block_event.cells`; bit `y << 8 | z << 4 | x`).  A fill
  that changes nothing queues nothing.  Boxes of 48 blocks or fewer in a section go through `mc.edit_section` (per-block events), larger ones through `mc.fill_section`.
* **Broadcast.**  Per tick the events are grouped by section.  Sections with one changed position get a `block_update` (the old code path); a section with two or more positions, or
  any fill, is encoded once as `section_blocks_update` (or `block_update` when the set has a single element): the positions in insertion order (events in id order, a fill's cells
  in `/fill` order) go through `mc.shortset_order`, their states are read from the section as it is *now* (`mc.section_state_ids`), exactly as vanilla reads `LevelChunkSection`.  Only
  sections some connection can see are encoded; one packet per section is fanned out to every connection in range.  A whole-section fill uses a constant order stored in
  `mc.sbu_const`.  Events of the old `kind = 'section'` (nothing writes them any more) still re-send the chunk.
* Changed from before: a position that changes and changes back is now announced (vanilla's set keeps it); the net-change logic remains for the break effect (`level_event` 2001
  for the connections other than the actor), which vanilla sends from the player's `destroyBlock`, not from `broadcastChanges`, and which dbcraft still sends for any removal by
  `mc.set_block` / `mc.set_blocks` (a deviation from `/setblock` and `/fill`, which send none).  A **fill never sends it** (vanilla's `/fill` does not).

Verification (the numbers are reproducible with the scripts named):

| Check | Result |
|---|---|
| `mc.shortset_order` against the real fastutil 8.5.18 class (`tests/bench/world/set_order.sh`: Java and SQL on the same sequences) | **100 sequences identical**: random with duplicates, distinct, ascending from 0 (the null key), every size around the rehash thresholds 24/25, 48/49 ... 3072/3073, boxes in `/fill` order, a whole section; 12 vectors pinned in `tests/sql/851` |
| the packets a client receives from a **real vanilla 26.3 server** and from dbcraft for the same steps (`tests/e2e/fill_probe.py`, `compare_fill.py`) | see below |
| `tests/sql/850_fill_cells.sql`: 434 random fills against the same boxes placed block by block with `mc.set_blocks` | equal section counts after every fill, equal blocks everywhere, equal palette / bits / packed bytes in every section not replaced whole, equal changed positions in every fill, equal heightmaps after the recompute; mutations of the SWAR count, the word mask and the mixed bit map are each caught |
| `tests/sql/851_section_updates.sql` (54 checks) | one position, two, change and change back, a fill, a block next to a fill, whole sections, invisible sections, the legacy section event, the break effect |

Real-server comparison (`tests/e2e/compare_fill.py`): a scripted client joins vanilla and dbcraft; the same 32 steps run (RCON `/fill` and `/setblock` on vanilla, SQL on dbcraft):
single block, two blocks, one-block fill, 17 fills of 24 to 4,096 blocks in one section (sizes on both sides of every rehash threshold), a fill that changes nothing, overlapping
fills, a fill to air, a fill over 9 chunks, a batch of 74 `/setblock` in one tick (a function), a block changed twice, a block changed and changed back.  **All 134 `section_blocks_update` packets (133,921 entries) and the 4 `block_update` packets were byte-identical** (`compare_fill.py`, vanilla with `gamerule random_tick_speed 0`; with random ticks on, grass at y = -61 decays to dirt under the stone and one of the 134 packets once carried that unrelated entry, which the script tolerates and reports).  Vanilla also sent `light_update` after some steps (one in the final run, more in earlier runs: it depends on the light engine's timing), which dbcraft does not (listed, not a failure).

**Not verified against vanilla:** `light_update` (vanilla sends it after block changes; there is no light engine here), `block_entity_data` after a block update of a block with a
block entity (dbcraft sends none), the order of sections of *different* chunks in one tick (vanilla's is a hash-map order; dbcraft sends chunk by chunk), `/fill` modes other than the
default (`hollow`, `outline`, `keep`, `destroy`, `replace <filter>`: they have no SQL counterpart yet), fills across dimensions, more than one connection per chunk
with different view distances.  Entities in deep sleep wake only near a fill's section corner (the trigger on `mc.block_event` looks at the event's x, y, z), the same limit the old
whole-section event had.

## Terrain generator (`dbcraft:noise`): believable, seeded, **not vanilla's**

`update mc.server_property set value = 'dbcraft:noise' where key = 'dbcraft.generator'` (default `minecraft:flat`) makes the overworld generate seeded terrain instead of the flat world,
for chunks generated from then on (existing chunks are not touched; `mc.generate_flat('minecraft:overworld', cx, cz, true)` regenerates one).  A trigger sets the overworld's
`mc.dimension.generator`, moves the world spawn onto dry land and puts it in `mc.game_state` (the join sends it); switching back restores the flat spawn (0, -60, 0).  The seed is
`mc.world.seed` (`update mc.world set seed = 12345 where name = 'world'`); the same seed always makes the same chunks, byte for byte, whatever the batch or the order.  Flat stays the
default and its output is unchanged (`tests/sql/855` generates a flat chunk through the dispatching path and compares it with the reference generator, sections and packet).
Every caller of `mc.generate_flat` (join, chunk streaming, the generation queue, the dev world reset) follows the setting, because `mc.generate_flat_batch` hands a dimension whose
generator is not the flat one to the registered function (`mc.generator`, sql/245); the dispatch costs one primary-key lookup, 2.8 µs.  **This is not vanilla's terrain and does not try
to be**: matching vanilla's seeds would mean porting its density functions, noise parameters, surface rules, carvers and features, which is a separate project.

What a chunk contains (sql/855; the file header has the details):

* **Height**: value noise at four scales (continents 512 blocks, hill amplitude 256, hills 96, detail 32), evaluated on the global 4-block lattice (a 5 x 5 grid of samples per chunk,
  so neighbouring chunks agree on their border) and interpolated to the 256 columns with a smoothstep, as vanilla interpolates its noise cells.  Sea level 63 (water up to y 62).
* **Biomes**: temperature and humidity noise (420 and 300 blocks) and the height choose one of **16 real biome ids** per 4 x 4 cell: deep ocean, ocean, cold, frozen, lukewarm and warm
  ocean, beach, desert, savanna, snowy plains, taiga, forest, plains, windswept hills, snowy slopes, jagged peaks.  The biome is constant over the height of a cell (vanilla's vary with y
  in caves and mountains).  Palette containers of 0, 1, 2 or 3 bits as the chunk needs (more than 8 biomes in one chunk, which does not happen with these noises, would collapse the rarest).
* **Blocks**: grass over three dirt (plains, forest, taiga, snowy plains, savanna), sand over sandstone (desert, beach), bare stone (windswept hills), snow block over stone (peaks), sand or
  gravel floors under water; stone below; **deepslate below y 0** (a sharp boundary, vanilla's is a gradient from 0 to -8); **bedrock** on y -64 and up to five layers per column (a hash,
  probabilities 1, .8, .6, .4, .2 as vanilla's, but one run per column rather than independent layers).  Stone and deepslate sections are single-value rows (no data bytes).
* **Not there**: caves, ravines, ores, aquifers, lava, trees, grass and flowers, snow layers, structures, villages, fluid flow, a gradient between biomes' surface blocks.  Rivers are not
  carved (low ground simply floods to sea level).
* **Heightmaps** are written with the chunk: WORLD_SURFACE = MOTION_BLOCKING = MOTION_BLOCKING_NO_LEAVES = the higher of the surface and the water (water has a fluid, so it counts for MOTION_BLOCKING),
  checked against `mc.compute_heightmaps` from the blocks (36 chunks per run, all three kinds, equal).  **Light** stays the straight-down model (the generator computes it right away with
  `mc.ensure_chunk_current`, together with the packet, in its own transaction, so the tick only reads the cache).

How it is built (why it is fast enough): value noise is PL/pgSQL with the integer hash inline (written as nested SQL functions the planner inlined every use of every intermediate value
into 8 copies: 0.5 ms per noise value instead of 8 µs); the 256 columns, the 16 cells and the 25 lattice samples are small loops; a section is text: every column is one character
(`chr(256 + height * 8 + type)`), the 256 entries of one y are one `translate` of that string, and the hex of 16 planes **is** the packed data, because the wire format's nibble order is the reverse of
the x order inside a row (the 4-bit case: 16 entries a long, entry 0 in the least significant nibble, longs big-endian).  Block and fluid counts are the lengths of the string with the
air or water digits removed.  Chunks are written in groups of 32 (rows as `mc.chunk` / `mc.chunk_section` composite arrays).

Cost, `tests/bench/world/bench_terrain.sql` (CPU time of the backend per chunk, 1,600 chunks per round, 5 rounds, median and min - max, other jobs on the machine):

| per chunk | CPU time |
|---|---|
| flat generator (rows, light and packet copied from the template) | **134 µs** (132 - 591) |
| `dbcraft:noise`, everything the generator call does | **5.15 ms** (4.47 - 20.9; the maximum is the first round, which plans the statements) |
|   of which the rows: heights, biomes, section text, inserts | 2.79 ms (2.48 - 18.9) |
|   of which light (`mc.ensure_chunk_current`) | 0.89 ms (0.72 - 0.96) |
|   of which the packet (`mc.chunk_packet`, cached afterwards) | 1.35 ms (1.27 - 1.46) |

That is 38 times the flat generator and, against the 1.8 ms the scoreboard measured for vanilla generating a FLAT chunk (`docs/SCOREBOARD.md`, 10,000 chunks in 17.8 s), 2.9 times.  I did **not**
measure vanilla generating real terrain here; its pipeline (noise, carvers, surface, features, lighting) costs far more per chunk than its flat one, and I would not quote a ratio without
running it.  Within the rows the 25 lattice samples are about 0.5 ms (6 noise values each), the bedrock hash 0.5 ms, the surface sections 0.7 ms.

For the async queue (`dbcraft.chunk-generation = async`, `call mc.run_generator()`, as many loops as cores): about 190 (1 / 5.15 ms of CPU, computed, not measured with several loops) chunks per second per loop.  **Run noise worlds in async mode**:
in the default inline mode a join at view distance 10 generates its 441 chunks inside the join, about 2.3 (441 x 5.15 ms, computed from the per-chunk cost, not a measured join) s for terrain against 70 ms for flat.

What was checked (tests/sql/855_terrain_noise.sql, 53 checks) and what was not:

| Check | Result |
|---|---|
| flat stays the default; its chunks and packets equal the reference generator's through the dispatching path; unknown generator names are refused; switching moves and restores the spawn | pass |
| determinism: same seed, same bytes in another dimension and when regenerated; another seed differs; one chunk generated alone equals the same chunk from a 144-chunk batch | pass |
| the stored heightmaps of 600 columns equal the surface function; neighbouring columns never differ by more than 3 blocks in the 12 x 12 region (bound asserted: 6), also across chunk borders | pass |
| the stored heightmaps of 36 chunks equal `mc.compute_heightmaps` from the blocks, all three kinds | pass |
| layering of 576 sampled columns: bedrock on -64 (1 to 5 layers, all five values occur), deepslate, stone, a surface block from the allowed set with air above, water at exactly y 62 over a sand or gravel floor | pass |
| `block_count` / `fluid_count` of 30 sections equal a count of their blocks; the wire bytes of 6 sections decode (by a decoder written for the test) to the stored blocks | pass |
| biome containers: 640 cells of 40 chunks decode (by a decoder written for the test) to the biome the noise functions give; container byte lengths; one container per chunk | pass |
| the generation queue produces the chunks with packets cached and clean | pass |
| mutations of the bedrock mapping, the plane boundary and the heightmap value are each caught | yes |
| **a real vanilla 26.3 server reads the exported terrain like the database** (`tests/world_import/terrain_vanilla.sh`: 800 sampled positions over 289 chunks, `execute if block`) | **pass: 800 sampled positions inside 17 x 17 chunks, 0 differ** (see below the table) |


The vanilla comparison needs a word: the first run sampled all 289 exported chunks and **4 of 800 positions differed** (the database said stone, vanilla answered `Test failed`).  All four were in the
outermost ring of chunks, at heights 21 to 50.  My explanation is that vanilla generates the missing neighbours of an exported area and its ore features spill into chunks that are already complete;
the run with two more rings exported than sampled (`terrain_vanilla.sh` does that now) had **0 of 800** differ, which fits but is not proof: I did not look at what vanilla had at those four
positions.  Only 10 distinct block states occur in the sample (stone, air, water, grass, dirt, sand, gravel, deepslate, bedrock, sandstone), which is what this terrain holds.  A scripted 26.3 client
(tests/e2e) also joined a dev gateway that served the noise world and received its 121 chunk packets (9 to 17 KB each) at view distance 4 with the spawn on dry land; no real client was run.

**Not verified:** a real client rendering it (no display here; `tools/realclient/` exists but was not run), that it "looks like Minecraft" beyond height and biome statistics (sea 20 to 60%, land
above 66 20 to 70%, hills above 100 present over 4,225 points 200 blocks apart; slopes at most 3 per block), the sizes of biomes against vanilla's, grass and foliage tints of the biome ids on
this terrain, long-term behaviour of several generator loops on one queue (the queue's own tests cover exactly-once), the light of overhangs (there are none), behaviour at coordinates beyond
about 100,000 blocks (the hash arithmetic is bounded, the tests stop at 4,000 blocks).

## Schema

| Table | Holds |
|---|---|
| `mc.dimension`, `mc.world` | what exists: type, `min_y`, `height`, default biome, spawn |
| `mc.biome`, `mc.dimension_type` | data-driven registry ids the client needs; loaded by `tools/load_world_ref.py` from a capture (biome id = alphabetical rank of the key; the test asserts it) |
| `mc.chunk` | per chunk: `version` (bumped by every edit), `dirty` (light needs recomputing), `hm_dirty` (heightmaps need a full recompute), three readable `smallint[256]` heightmaps |
| `mc.chunk_section` | one 16x16x16 section: `palette text[]` of block-state names (empty = global palette), `bits`, packed `data bytea`, `block_count`, `fluid_count`, biome palette/bits/data |
| `mc.chunk_light` | one row per light layer: `sky_kind`/`block_kind` (`data`, `empty`, or NULL = absent) and the 2048-byte arrays |
| `mc.block_entity` | chests, signs, …; `nbt` is the raw network NBT (see gaps) |
| `mc.chunk_cache` | the finished framed packet per chunk, valid while `version` matches |
| `mc.block_event` | block changes for the tick to broadcast (the only unlogged table; transient): one row per changed block (`kind = 'block'`) or one per section a fill changed (`kind = 'cells'`, a 512-byte bit map of the positions) |
| `mc.flat_layer` | the flat generator's layers per dimension (default: bedrock, 2 dirt, grass_block) |

World data is **not** unlogged.  `mc.chunk_section` uses `fillfactor 70`, `toast_tuple_target 8160` and `STORAGE MAIN` so sections stay inline (byte loops over a detoasted
value are quadratic, see `docs/COMPRESSION.md`).  A section with no palette growth is 0.2 to 3 KB; the largest seen was 7.2 KB.

## API

```sql
mc.get_block(dim, x, y, z)                   -- state name; NULL when the chunk does not exist; 'minecraft:air' for a missing section
mc.set_block(dim, x, y, z, block)            -- true when it changed
mc.set_blocks(dim, xs[], ys[], zs[], blocks[])  -- batched: one read + write per touched section; returns blocks changed
mc.fill(dim, x1, y1, z1, x2, y2, z2, block)  -- per section: a whole section becomes single-value, a partial box is written word by word (no unpacking); returns blocks covered
mc.compact_section(dim, cx, sy, cz)          -- minimal palette again; an all-air section is deleted
mc.generate_flat(dim, cx, cz [, replace]) / mc.generate_flat_area(dim, cx1, cz1, cx2, cz2)
mc.chunk_packet(dim, cx, cz)                 -- framed bytes, cached; recomputes derived data first if the chunk is dirty
mc.chunk_packet_body(dim, cx, cz)            -- the packet body without framing or cache
mc.ensure_chunk_current(dim, cx, cz)         -- recompute heightmaps (if flagged) and light
mc.blocks                                    -- readable view of every non-air block, with INSTEAD OF INSERT/UPDATE/DELETE triggers
mc.blocks_in(dim, x1, y1, z1, x2, y2, z2)    -- the same restricted to a box (touches only the overlapping sections)
mc.block_at(dim, x, y, z)                    -- one row of that shape, air included
```

`block` is a full state name (`minecraft:oak_log[axis=x]`) or a bare block name (its default state).  Palette growth is handled across every bit width:
single → 4 bits → 5 … 8 bits → global (tested by placing 300 distinct blocks and reading all back at each threshold).  Edits keep the three heightmaps exact
incrementally (raise on a higher block, rescan one column when its top block goes); a property test compares them with a full recompute after 4,000 random edits.
Fills (every section of more than 48 blocks of the box; smaller pieces keep the incremental path) and imports flag `hm_dirty` and the next send recomputes in full.

Postgres detail worth knowing: `get_block` is `STABLE`, so inside a single `SELECT` it cannot see a `set_block` made by the same statement; separate statements see each
other's changes, as all game logic does.

## Performance

Measured on the 4-core dev container with other benchmark processes running, so treat numbers as ±25%.  `tests/bench/world/bench_world.sql` prints them;
`pgbench_set_block.sql` / `pgbench_get_block.sql` give per-transaction rates.  The tick budget is 50 ms.

> **These numbers are from before the chunk performance work** (template generation, the single-edit path, the generation queue).  Generating a flat chunk is now
> about 0.35 ms (was 9 ms), a single `set_block` about 0.25 ms (was 0.6 ms), a first-time join at view distance 10 about 70 ms (was 7 s).  Current figures, method and
> what is still slow: [PERF-CHUNKS.md](PERF-CHUNKS.md).

| Operation | Measured |
|---|---|
| `generate_flat` one chunk (sections, heightmaps and light) | 8 to 10 ms (it was 90 ms before the heightmap CTE was materialized: the planner re-evaluated the palette flags 4,096 times per section) |
| `set_block`, each edit its own transaction (pgbench) | **0.57 to 0.70 ms**, 1,430 to 1,750 edits/s on one connection |
| the same on **4 connections**, each in its own region | **6,350 to 7,100 edits/s** (about 4x: writes to different rows scale across connections) |
| `get_block` | 0.065 ms round trip (15,400/s) over pgbench; about 20 to 40 µs inside the database |
| `set_blocks`, 10,000 edits inside one section | 46 to 100 ms |
| `set_blocks`, 10,000 edits spread over 16 / 64 / 448 sections | 66 to 113 ms / 116 to 158 ms / 440 to 540 ms (0.2 to 1.2 ms per touched section) |
| `set_blocks`, 100 edits scattered over 88 sections | 17 to 44 ms |
| `fill`, one whole section / 64 whole sections | see "Large fills" below |
| `fill`, 16x1x16 floor / unaligned 40x40x40 | see "Large fills" below |
| `chunk_packet`, flat chunk, cache hit | 22 to 24 µs |
| `chunk_packet`, flat chunk, cold (derived data current) | 4 to 9.5 ms |
| one edit, then `chunk_packet` (light recompute + re-encode) | 2.8 to 5.9 ms |
| `chunk_packet_body`, real terrain chunk (24 sections, about 11 palette) | 16 to 20 ms |
| `compute_heightmaps` in full, flat / real terrain | 4 to 5 ms / 44 to 49 ms (only after a whole-section fill or on import) |
| `compute_light`, flat / real terrain | about 1 ms / 1.7 to 2.3 ms |
| storage: flat chunk / real terrain chunk (all section rows) | 2.4 KB / 40.5 KB on average (palette sections average 3.4 KB, single-value 173 B) |

### Large fills (sql/210 `mc.fill_section`, measured for this change)

`mc.fill` used to push every block of a partial section through `mc.edit_section`: one palette lookup, one bit of surgery, one heightmap step and **one event row per
block** (about 5 µs a block, 100,000 blocks = 100,000 rows in `mc.block_event`, an identity primary key and an index).  Now a section the box covers is handled by
`mc.fill_section` and a fill queues one `cells` row per section (512 bytes) instead.  A/B in one session, the old function kept as `bench_old.fill`
(`tests/bench/world/ab_fill.sql`, 9 rounds, CPU time of the backend per call in ms, median and min - max; three runs, load average 2.5, the three runs agree within the
ranges shown; the 100,000-block scenario is the scoreboard's `fill -25 -60 -25 24 -21 24`, stone and air alternating so every call changes every block):

| Scenario | before | after | speed-up |
|---|---|---|---|
| fill 1,000 blocks (10x10x10) | 5.6 to 6.1 ms (5.4 - 8.9) | **0.78 to 0.92 ms** (0.68 - 1.4) | 6.9x to 7.0x |
| fill 100,000 blocks (50x40x50, 48 sections touched) | 469 to 491 ms (437 - 521) | **37 to 39 ms** (36 - 55) | 11.9x to 12.3x |
| unaligned 40x40x40 (64,000 blocks) | 310 to 312 ms (300 - 481) | **29.7 to 30.4 ms** (27.4 - 39) | 10.3x to 10.7x |
| 16x1x16 floor | 2.7 to 3.0 ms | 1.0 to 1.1 ms | 2.5x to 2.6x |
| 100 blocks in a section (box path) | 1.8 ms | 1.2 ms | 1.5x |
| 40 blocks in a section (the per-block path, unchanged apart from sorting its positions) | 1.4 to 1.5 ms | 1.6 to 1.7 ms | **0.9x (slower)** |
| one whole section (16x16x16), the section was single-valued | 0.31 to 0.33 ms | 0.42 to 0.46 ms | **0.7x (slower)**: a section is read before it is replaced (to know which positions change) and the event carries a bit map |
| 64 whole sections | 13 to 17 ms | 13 to 16 ms | 1.0x to 1.1x |

The scoreboard's own statements (`tools/scoreboard/fill_dbcraft.py`: 16 fills of 1,000 and 6 of 100,000 blocks in one psql session, `\timing`, five repetitions on the shared
dev cluster): **before 7.2 ms / 691 ms (p50, median of the repetitions), after 1.43 ms / 42.8 ms** (the 100,000-block calls ranged 39.5 to 79.7 ms).  The first call of a session costs
about 13 ms more (plans).  The vanilla numbers of the scoreboard (9.98 ms and 201 ms) were not re-run, see docs/SCOREBOARD.md.

Where the 100,000 blocks went and what became of it (the 535 ms of the scoreboard, about 5 µs a block):

* **the event per block**: 100,000 inserts into an unlogged table with an identity primary key, about 1.5 to 2 µs each (PERF-EDIT.md), then read again by the broadcast and grouped
  by position.  Now 48 rows.  This is also what makes the packets the real server's (above): the broadcast needs the *set* of positions, not the old and new state of each.
* **the per-block surgery** (a plpgsql loop of about ten statements per block): replaced by a loop over the *rows* of the box (one `y`, one `z`, the x range = one to three 64-bit
  words), about 250 iterations a section.  Masks come from two lookup tables (bit 0 of the first j fields, all bits of the first j fields), the new word is
  `(old and not mask) or (new value and mask)`.
* **counting**: the block count and fluid count of a section need the number of air and fluid entries inside the box before the fill.  They are counted with a SWAR zero-field test
  (`y = word xor (value in every field)`, OR-fold the field's bits onto its bit 0, mask, `bit_count`) on the words, no unpacking.  It is a quarter to a third of what is left
  (with the counting loop switched off the 100,000-block fill took 25 to 30 ms instead of about 35 in one noisy experiment).
* **heightmaps**: no longer maintained per block; the chunk is flagged `hm_dirty` and recomputed in full (4 to 5 ms flat, 44 to 49 ms real terrain per chunk) when something needs its
  packet.  Pieces of at most 48 blocks keep the incremental path.  This moves cost rather than removing it for a fill into real terrain that is then re-sent: the 16 chunks of the
  scoreboard fill would cost 16 x 45 ms at the next join into that area.  (Chunks in view are NOT re-sent any more: the broadcast sends section packets, not chunks.)
* what is left per section (about 0.7 ms): reading and rewriting the 2 KB row, the words array (256 `proto.i64_read`), the row loop, the counting.  The rows of a section are 4 KB
  of WAL each (full-page images aside).  I did not specialise the 4-bit case further.

What these mean against a 50 ms tick:

* **10,000 edits per tick fit only when they are concentrated** (about 16 sections or fewer: 66 to 113 ms measured here, so even that is over budget on one connection).
  Spread over hundreds of sections it is 0.4 to 0.5 s.  The cost is per touched section (read the row, rewrite it, bump the chunk), not per edit.
* A **few hundred scattered edits per tick are fine** (tens of ms); thousands are not on one connection.  Edits to different chunks scale across connections (4x on 4 here),
  so region-per-connection sharding is the way to spend more cores; nothing was tuned for that yet.
* Sending a chunk that has not changed is nearly free (the cache).  Re-sending an edited flat chunk is about 3 to 6 ms; an edited **terrain** chunk is dominated by
  re-encoding (16 to 20 ms) because every section is re-encoded.  Caching the encoded bytes per section would remove most of that (not done).
* The `mc.blocks` view is an unrestricted scan: see the next section.

## The readable view and `WHERE x = .. AND y = .. AND z = ..`

`mc.blocks` is a normal updatable view (`UPDATE mc.blocks SET block = 'minecraft:gold_block' WHERE x = 1 AND y = -61 AND z = 2` works, as do INSERT and DELETE).
**It does not look blocks up by coordinate.**  Postgres cannot turn `x = 5` into a section lookup, because `x` is computed from the section and the index inside it, so
the view unpacks every section with a non-air block before it filters.  Measured with 1,846 sections in the database: **1.2 s** per query (about 0.6 ms per section), and
`UPDATE mc.blocks … WHERE x,y,z` pays the same scan before it edits.

Use these instead for anything but a small world:

* `mc.block_at(dim, x, y, z)`: one row, **41 µs**.
* `mc.blocks_in(dim, x1, y1, z1, x2, y2, z2)`: only the overlapping sections are unpacked: **4.5 ms for a single section, 70 ms for 16 sections** (about 4 ms per section: the
  unpack is about 1 µs per block).
* `mc.set_block` / `mc.set_blocks` / `mc.fill` for edits.

I looked for a way to give the view real coordinate pushdown and found none without a C planner support function or a physical per-block table (billions of rows).  Two
performance bugs in the view itself were fixed on the way (the palette air flags were re-evaluated per block); the remaining cost is the unpack.

## Gaps and next steps

* **Compression.**  `mc.chunk_cache` holds the uncompressed framed packet.  `docs/COMPRESSION.md` describes the plan (per-section deflate fragments, an RLE-style encoder
  in SQL or a tiny native function); nothing of it is built here.
* **Block entity NBT** is stored as the raw network bytes, not as a readable representation.  Editing or inspecting a chest means decoding bytes.
* **No biome editing API** (sections carry biomes; nothing sets them after generation), no vanilla terrain generator (flat, and the seeded `dbcraft:noise` above, which is not vanilla's: no caves, ores, trees), no structures.
* **Light** is the straight-down model above; no horizontal sky spread, no block light, no cross-chunk updates.
* **Cache invalidation of neighbours.**  Light does not depend on neighbours in this model, so editing a chunk invalidates only that chunk's packet.
* **Per-section encoded bytes are not cached**, which is the main cost of re-sending an edited terrain chunk (see Performance).
* **Autovacuum.**  Each edit rewrites a section row (and the chunk row): under steady editing the heap bloats until vacuum runs (the bench database shows 61 MB for
  about 1,800 live sections after 20,000+ edits with no vacuum).  `fillfactor 70` helps HOT updates; autovacuum settings for these two tables were not tuned.
* **Sections past 8 KB** (a global-palette section is 8,192 bytes of data alone) cannot stay inline in an 8 KB page and are toasted; rare, and not measured.

## Reproducing the oracle tests

The tests need a vanilla 26.3 server and its captures, none of which is committed (they contain Mojang data):

```
# flat world (the parent session's capture): tests/fixtures/captured/play_nocomp.jsonl, from tools/capture_vanilla.py against a flat-world server
# real terrain: start a second server with a normal world (level-seed set, view-distance 3, online-mode=false, network-compression-threshold=-1,
# white-list=false, a free port) and capture it:
python3 tools/capture_vanilla.py --port 25571 --seconds 15 --out /tmp/dbcraft-fixtures/terrain_nocomp.jsonl
tests/sql/run.sh world            # runs 200_*, 210_*, 240_*, 250_* (set DBCRAFT_TESTDB to keep runs apart)
```

The oracle tests skip with a clear notice when a capture is missing; the rest of the suite does not need them.  Tools: `tools/load_world_ref.py` (biomes and dimension
types), `tools/import_chunk_capture.py` and `tools/extract_chunk_fixture.py` (feed captured chunks to the tests), `tools/_capture.py` (shared parsing).

## Scripts for the block-packet and terrain evidence

```
tests/e2e/record_vanilla.sh ; tests/e2e/run_all.sh        # records vanilla's fill packets (RCON), compares dbcraft's (compare_fill.py)
tests/bench/world/set_order.sh DB                         # mc.shortset_order against the real fastutil class (Java + SQL)
psql -X -d DB -v rounds=9 -f tests/bench/world/ab_fill.sql        # old fill against the box fill, interleaved
python3 tools/scoreboard/fill_dbcraft.py --db DB           # the scoreboard's fill statements against any database
psql -X -d DB -v rounds=5 -f tests/bench/world/bench_terrain.sql  # flat against noise generation, split into rows / light / packet
tests/world_import/terrain_vanilla.sh 8                    # vanilla loads an exported noise world; sampled positions compared
```

## Chunk rebuild and batched edits (details and numbers: PERF-EDIT.md)

* `mc.chunk.light_ws` / `light_top` are a **cache key**: the inputs (WORLD_SURFACE heightmap, highest non-empty section) the stored `mc.chunk_light` rows were computed from.  `mc.compute_light` does nothing when they still match
  (and the row count is right); NULL means "recompute".  Anything that writes light rows directly (the template copy in sql/245 copies the template's key) must set or null it.
* `mc.set_blocks` processes sections in key order through `mc.edit_section_core` with per-chunk bookkeeping and one event insert; `mc.edit_section` (one section) is a wrapper around the same core.
  A section stores exactly `ceil(4096 / (64 / bits)) * 8` bytes of packed data (the first versions stored twice that when a few edits created a palette section; see PERF-EDIT.md for the repair statement).
* The world code looks block states up by name through a hash index on `ref.block_state(name)`.
