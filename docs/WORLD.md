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
| `mc.block_event` | block changes for the tick to broadcast (the only unlogged table; transient) |
| `mc.flat_layer` | the flat generator's layers per dimension (default: bedrock, 2 dirt, grass_block) |

World data is **not** unlogged.  `mc.chunk_section` uses `fillfactor 70`, `toast_tuple_target 8160` and `STORAGE MAIN` so sections stay inline (byte loops over a detoasted
value are quadratic, see `docs/COMPRESSION.md`).  A section with no palette growth is 0.2 to 3 KB; the largest seen was 7.2 KB.

## API

```sql
mc.get_block(dim, x, y, z)                   -- state name; NULL when the chunk does not exist; 'minecraft:air' for a missing section
mc.set_block(dim, x, y, z, block)            -- true when it changed
mc.set_blocks(dim, xs[], ys[], zs[], blocks[])  -- batched: one read + write per touched section; returns blocks changed
mc.fill(dim, x1, y1, z1, x2, y2, z2, block)  -- whole sections are replaced without unpacking; returns blocks covered
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
Whole-section fills and imports flag `hm_dirty` and the next send recomputes in full.

Postgres detail worth knowing: `get_block` is `STABLE`, so inside a single `SELECT` it cannot see a `set_block` made by the same statement; separate statements see each
other's changes, as all game logic does.

## Performance

Measured on the 4-core dev container with other benchmark processes running, so treat numbers as ±25%.  `tests/bench/world/bench_world.sql` prints them;
`pgbench_set_block.sql` / `pgbench_get_block.sql` give per-transaction rates.  The tick budget is 50 ms.

| Operation | Measured |
|---|---|
| `generate_flat` one chunk (sections, heightmaps and light) | 8 to 10 ms (it was 90 ms before the heightmap CTE was materialized: the planner re-evaluated the palette flags 4,096 times per section) |
| `set_block`, each edit its own transaction (pgbench) | **0.57 to 0.70 ms**, 1,430 to 1,750 edits/s on one connection |
| the same on **4 connections**, each in its own region | **6,350 to 7,100 edits/s** (about 4x: writes to different rows scale across connections) |
| `get_block` | 0.065 ms round trip (15,400/s) over pgbench; about 20 to 40 µs inside the database |
| `set_blocks`, 10,000 edits inside one section | 46 to 100 ms |
| `set_blocks`, 10,000 edits spread over 16 / 64 / 448 sections | 66 to 113 ms / 116 to 158 ms / 440 to 540 ms (0.2 to 1.2 ms per touched section) |
| `set_blocks`, 100 edits scattered over 88 sections | 17 to 44 ms |
| `fill`, one whole section / 64 whole sections | 0.09 to 0.1 ms / 3.6 to 5.2 ms |
| `fill`, 16x1x16 floor / unaligned 40x40x40 | 0.5 to 0.7 ms / 80 to 85 ms |
| `chunk_packet`, flat chunk, cache hit | 22 to 24 µs |
| `chunk_packet`, flat chunk, cold (derived data current) | 4 to 9.5 ms |
| one edit, then `chunk_packet` (light recompute + re-encode) | 2.8 to 5.9 ms |
| `chunk_packet_body`, real terrain chunk (24 sections, about 11 palette) | 16 to 20 ms |
| `compute_heightmaps` in full, flat / real terrain | 4 to 5 ms / 44 to 49 ms (only after a whole-section fill or on import) |
| `compute_light`, flat / real terrain | about 1 ms / 1.7 to 2.3 ms |
| storage: flat chunk / real terrain chunk (all section rows) | 2.4 KB / 40.5 KB on average (palette sections average 3.4 KB, single-value 173 B) |

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
* **No biome editing API** (sections carry biomes; nothing sets them after generation), no terrain generator other than flat, no structures.
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
