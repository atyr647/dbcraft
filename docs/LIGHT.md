# The light engine

Sky light and block light as vanilla 26.3's engine (`net.minecraft.world.level.lighting.*`) leaves them, computed in SQL from the stored blocks; light after edits; the `light_update`
packets.  Before this, light was the straight-down sky model of `sql/220` (exact for flat worlds, 76% of the sky layers of real terrain, no block light, no light updates).

Everything here was read from the 26.3 classes (decompiled locally with the jar's own names) and checked against the real server; "exact" below means a recording or a vanilla
save file says so, and the numbers are in "Evidence".

## What vanilla's engine does (the part that matters)

* The light of a cell is a **fixed point** that does not depend on the order of the updates (`LightEngine.propagateIncrease` / `propagateDecrease`): the larger of the cell's own
  emission and `light(neighbour) - max(1, dampening(cell))` over the six neighbours, a neighbour that is not shut off by **occluding face shapes**
  (`LightEngine.shapeOccludes`: `Shapes.faceShapeOccludes` of the face of the neighbour towards the cell and the face of the cell towards the neighbour, both empty unless the
  state `canOcclude` and `useShapeForLightOcclusion`).  Dampening is `BlockState.getLightDampening()`: in 26.3 only 0 (air, glass, torches, slabs, stairs ...), 1 (water, leaves, ice ...)
  and 15 (opaque) occur.  A cell with dampening 15 can only hold its own emission.
* **Block light** starts at the emission of the cells (`BlockState.getLightEmission()`, 0 .. 15).
* **Sky light** starts with 15 in every *source* cell: `ChunkSkyLightSources` keeps per column the lowest source, the cell above the highest edge for which
  `isEdgeOccluded(top, bottom)`: the cell below has dampening != 0, or the two cells' face shapes together cover the square.  Sources are 15 whatever the dampening above them, which is
  why the straight-down model was exact for terrain without overhangs; below the source line the light spreads in every direction (water and leaves cost 1 like air).
* A **layer** (one 2,048-byte array per 16-cell section, indices 0 .. sections + 1, layer 0 below the world) exists for every section that has a non-empty section among its 26
  neighbours (`LayerLightSectionStorage.SectionState`: neighbour counts; neighbours include other chunks).  The packet carries, per layer, the array when it holds light (`data`), or
  the bit "empty" when it does not.
* `ClientboundLightUpdatePacketData`: the same four bit sets and two array lists as the chunk packet, for the sections in the **change filter** only.  The filter is
  `ChunkHolder.sectionLightChanged`, called for every section of `SectionPos.aroundAndAtBlockPos` of a cell whose stored light was written.  `ChunkHolder.broadcastChanges` sends the
  packet only to players for whom the chunk is **on the border of the tracked square** (`ChunkMap.getPlayers(pos, borderOnly = true)`: the chunk is tracked and at least one of its 8
  neighbours is not): the other clients run the light engine themselves.

## The data (`tools/gen_light.sh`, `tools/load_light.py`)

`tools/java/LightDump.java` boots the jar's registries (as `DynDump` does) and asks every block state for emission, dampening, `canOcclude && useShapeForLightOcclusion` and the six
`LightEngine.getOcclusionShape(state, direction)` face shapes; it also evaluates `Shapes.faceShapeOccludes` over every pair of the 56 distinct face shapes (520 occluding pairs).
Output `light_states.tsv` (not committed), loaded into `mc.light_state` (35,723 states), `mc.light_face`, `mc.light_face_occ` (`sql/221`).  Without the data, or with
`set dbcraft.light_engine = 'off'`, `mc.compute_light` is the old straight-down model (`mc.compute_light_flat`).

## The algorithm (`sql/222` .. `sql/227`)

**Level sets instead of cells.**  Every step costs at least 1, so the cells of light >= L follow from the cells of light >= L + 1: the engine computes the waves from 15 down to 1
(`mc.light_waves`, one SQL statement per level), over PostgreSQL bit strings, one `bit(4096)` per section and property: passable cells, sky sources, emitters per level, visited
cells, the four bit-planes of the level.  A wave step is a handful of shifts and ANDs per section (neighbour sections contribute their face planes), only the cells that were new at
the level before are expanded, a section without a front costs nothing.  The cell layout inside a bit string ("layout M", `sql/222`) is the order in which the hex form of a
4-bit palette section lists its cells, so the masks of the common section need one `encode(.., 'hex')` and one `translate()` per class, no unpacking; other widths unpack the entries.

**Which sections take part** (`mc.light_region`, `sql/225`): the chunks to light and their existing neighbours (light travels 14 cells, a chunk is 16 wide).  Sky: every column is
scanned from the top of the world down (a suffix OR of "has dampening" over the section, carried from the section above) until each column has such a cell; then one section below
the lowest source section of the neighbourhood.  Block: the sections whose palette holds an emitting state and their 26 neighbours.  Sections not taken part cannot hold light
that reaches a target chunk.

**Shapes** (`mc.light_shapes_prepare/apply`): the cells of states that use their occlusion shape are unpacked (rare: slabs, stairs, snow layers, paths, farmland), every edge
between such a cell and a neighbour whose two face shapes cover the square becomes a bit in a per-section, per-side "cannot receive from this side" mask; the waves AND it into
the contribution of that direction.  The same masks end the sky sources of a column at a shape-occluded edge.

**Output** (`sql/223`): the four planes become the 2,048-byte array by a Morton spread of each plane (12 rounds of shift / OR / AND over 16,384-bit strings), a byte swap inside every
64-bit word (layout M lists a row of 16 cells from x = 15 down) and a cut into longs.  A layer is `data` when it holds any light, `empty` otherwise; layers present are the sections
within one section of a non-empty section of the 3 x 3 chunks.

**Incremental updates** (`mc.light_update`, `sql/227`): an edit changes light only where it travels, so the sections that intersect the cube of +-14 cells around the changed cells
are lit again with the same waves ("free" sections); the sections next to them ("frozen") keep their stored light and **start waves at their stored level**, which is exactly the
inflow from outside; the sky sources of a free section end where the stored section above ends them (its cell below the 15s: a column "has dampening above").  A sky source that
appears or disappears sends light down its column as far as the next cell with dampening, so the cube reaches down there.  Changes the cube cannot express (more than 120 sections;
a section that becomes empty or non-empty, which changes which layers exist in three chunks) answer -1 and the caller lights the chunks around again with `mc.light_region`.  A layer
that holds light keeps its `data` form when light is removed from it (vanilla's arrays are never freed once written, so it sends an all-zero `data` array).

## Wiring

| Piece | What |
|---|---|
| `mc.compute_light(dim, cx, cz)` (`sql/220`) | the engine for one chunk, or the straight-down model where `mc.light_flat_ok` proves they agree (the chunk and its neighbours have one constant surface height, full sections below, nothing above, only air and opaque non-emitting palette states: every flat world) |
| `mc.light_chunks(dim, cxs, czs)` (`sql/226`) | light of freshly created chunks in one region; the noise generator (`sql/855`) calls it for each batch.  Existing neighbours that were lit while the new chunks were missing are lit again and get a new version |
| trigger `light_queue` on `mc.block_event` (`sql/228`) | every block change goes into `mc.light_dirty` with an *effect* (1 sky, 2 block: `mc.light_effect` compares dampening, emission and shapes of the old and new state; vanilla's `hasDifferentLightProperties`).  No change in `mc.set_block`, `fill`, the dynamics or the importer |
| `mc.light_step(tick)` (`sql/228`), one line in `mc.tick_core` (`sql/837`, after the dynamics) and one in `mc.server_tick` (`sql/430`, after the players' block actions, before the block packets are broadcast) | empties the queue: cells -> `mc.light_update` (fills of more than 64 cells and whole sections: `mc.light_region` of the chunks around), new `mc.chunk.version` for chunks whose light changed, `light_update` packets for the connections for which the chunk is on the border of their view (`net.conn.view_cx/cz`, radius `view-distance + 1`) |
| `mc.light_at(dim, x, y, z, 'sky' or 'block')` | the stored light of one cell |

The marks of a packet (`mc.light_marks`): a changed section, and every neighbouring section (also over edges and corners) that a changed cell touches at the section's border: what
`aroundAndAtBlockPos` adds for a written cell.

**Hooks on other code** (everything else is new files): a statement trigger on `mc.block_event` (`light_queue`, sql/228) that only copies rows; one `perform mc.light_step(cur)` in `mc.tick_core`
(sql/837) and one guarded call in `mc.server_tick` (sql/430); the dispatcher `mc.compute_light` in sql/220 (the old function is `mc.compute_light_flat`); one call to `mc.light_chunks` in the noise
generator (sql/855).  `set dbcraft.light_engine = 'off'` turns the engine off (the trigger stops queuing, the old model lights chunks).

## Evidence

All of it is reproducible with the scripts named; the vanilla world and the recordings are Mojang data and stay out of git.

1. **A world vanilla generated and saved** (`tests/light/vanilla_world.sh`: seed 7041, 721 full chunks in 4 region files: swamp, ocean, grass land, hills, caves with lava and glow lichen,
   a village).  Imported with `tools/world_import.py` (the light rows come from the files), every chunk lit again from its blocks by `mc.light_region`, compared layer by layer with the file's
   light (`tests/light/compare_import.sql`):

   | chunks (all their neighbours present, within 1 / 2 / 3 chunks) | layers | sky arrays that differ | block arrays that differ | layer sets that differ |
   |---|---|---|---|---|
   | 612 | 7,438 | **0** | 10 | 0 |
   | 512 | 6,195 | **0** | 9 | 0 |
   | 420 | 5,064 | **0** | 6 | 0 |

   The block arrays that differ are all of one kind: vanilla's file holds an allocated array of zeros (`data`, where this engine writes `empty`): the same light (see "approximate").  Cell for
   cell, every value of sky and block light of all 612 chunks equals vanilla's, villages (slabs, stairs, paths, farmland: the shapes), caves, lava, glow lichen, water and leaves included.
   (Chunks at the edge of what vanilla generated are not comparable: it lit them before the features of the chunks around them were finished, which the saved light shows; the older capture of
   `tests/sql/250` is such a world and its report is informational for that reason.)
2. **The real server after edits** (`tests/light/compare_edits.py`): a vanilla 26.3 server loads a copy of that world, the same world is in a dbcraft database, both get the same edits
   (RCON `/setblock` and `/fill` on vanilla with ticks frozen, `mc.set_block` / `mc.fill` and one `mc.light_step` on dbcraft); after every step a scripted client joins vanilla and records the 49
   chunks around the spawn; `tests/world_import/compare_chunks.py` compares light masks and arrays with dbcraft's packets.  The start and nine sets of edits: torches (also at a chunk border), glowstone
   and a sea lantern, a shaft (20 blocks removed), a roof (43 blocks placed), a 16-block stone pillar and its removal, lava + a slab + stairs + leaves, torches and glowstone at a chunk border, a fill of 2,976 glass
   blocks over three chunks.  **10 of 10 snapshots: all 49 chunks identical in every light mask and every array** (the first run found one chunk whose cached packet was not invalidated when it
   gained a light layer; fixed, see `mc.light_step`).
3. **`light_update` packets** (`tests/light/e2e_light.sh`, `tests/e2e/light_probe.py`): one scripted client in a flat world, 15 edit steps in the chunks at, inside and outside the border of the
   tracked square, RCON on vanilla and SQL on dbcraft through the gateway; per step the `light_update` packets of both servers compared as byte strings.  **14 of the 15 steps are identical** (same chunks, same layers, same arrays, same number of packets), also in a fresh vanilla world
   (the client is teleported to chunk (0, 0) first: a fresh world spreads its player); the 15th, a slab placed in a cell that a glowstone lights from 9 cells away, differs in the marks: vanilla marks the
   block layer of two chunks whose light did not change (its decrease wave zeroed cells that the increase wave then lit again to the same value), this engine marks what changed.
4. **Incremental against full** (self-consistency, no vanilla): on the imported terrain 190 random edits (stone, torch, glowstone, water, leaves, glass, lava, slabs, stairs, dirt, air at heights
   around the surface) each followed by `mc.light_update` and then by a full `mc.light_region` of the 3 x 3 chunks around: no layer differs, no fallback needed in 190 of 190 (`tests/sql/221` repeats
   14 of them on noise terrain, and checks block light values by hand: a torch gives 14, 13, 12 ... 1 over 13 cells, across chunk borders, a roof gives 14 at its edge and 13 in the middle).
5. **Flat worlds**: 49 of 49 recorded flat chunk packets still byte-identical (`tests/sql/240`), the engine and the straight-down model give the same rows for a flat area (`tests/sql/221`),
   the whole SQL suite passes (92 files, 3,684 checks, 3 jobs, 876 s wall).

## What is exact, what is approximate

**Exact** (checked against the real server, see Evidence): sky and block light of imported vanilla terrain, cell for cell, including villages (shapes), caves, water, leaves, lava
and glow lichen; the light after edits (torches, glowstone, sea lanterns, shafts, roofs, pillars put up and removed, lava, slabs, stairs, leaves, a 31 x 16 x 6 fill), array by
array; the `light_update` packets of 14 of 15 edit steps (same chunks, same layers, same arrays, same number of packets); the 15th differs in which sections are marked (below).

**Approximate or not done:**

* **All-zero `data` arrays.**  Vanilla sometimes holds a layer as an allocated array of zeros (light that was there during generation and was cleared; light removed by an
  edit) and sends it as `data`; a layer computed from the blocks alone cannot know that and is `empty` (6 of 5,064 layers in the imported comparison).  After an edit the layer's
  stored form is kept, which is vanilla's behaviour.  Both forms mean the same light.
* **Which sections a `light_update` marks.**  Vanilla marks every section where a cell was *written*, including cells that its decrease wave set to 0 and the increase wave set back to the
  same value (a block placed or removed in a cell that has light: `checkNode` zeroes the cell and every cell downhill of it, then lights them again); this engine marks the sections of cells whose
  value changed (and the neighbours those touch at their border).  They agree in 14 of the 15 recorded steps and in the packets of every edit that only adds light or only removes it where no other
  source is near; the 15th step above is the case that differs: a light removed or blocked where another source keeps most of the cells lit makes vanilla mark one or two sections more.  Marks are
  what the packet carries, not what the light is: the arrays in the packets that both servers send are equal.  Closing this means computing vanilla's decrease region (the cells reached from the
  changed cell by steps to a strictly lower level) with the same bit-set waves; not done.
* **Timing.**  The step runs after the dynamics (`mc.tick_core`) and again after the players' block actions, before the block packets: a `light_update` leaves in the tick of the change, ahead of
  the block packets of that tick.  Vanilla's engine is asynchronous: in the 14 recorded steps with both packets the light packet came in the same tick 12 times (0 to 16 ms after the block packet)
  and in the next tick twice (42 and 60 ms); the order of the packets within a tick is not fixed there either (recorded both ways).  The comparison is per step, not per tick.
* **Chunks next to missing chunks.**  Vanilla only completes a chunk whose neighbours exist.  Here a chunk is lit with the neighbours that exist; when a neighbour is created later the
  chunk is lit again and its version bumped (a new send is right), but a client that already holds it gets no `light_update` for that.  Imported worlds and flat worlds do not hit this.
* **Layers created or removed** (a first block in an empty section, the last block removed) light the three chunks again and vanilla's extra `light_update` marks for the new layers are not sent.
* **Sky light in other dimensions** (no sky light in the Nether, a ceiling in the End): only the overworld exists.
* The change filter is also not applied to chunks that are not "ticking" in vanilla (a chunk at the border of the view that the simulation distance does not reach: vanilla's
  `getTickingChunk()` is null and it sends nothing); the recorded setup (simulation distance 2, view distance 2) sent border updates, so border chunks were ticking there.

## Costs

CPU time of the 4-core dev container, quiet machine, steady state (a long-lived session: the first call of a session also plans about 25 statements).

| | straight-down model (before) | light engine |
|---|---|---|
| a flat world (every flat chunk) | 0.15 to 0.3 ms | the same (`mc.light_flat_ok` proves the model exact: 0.05 ms more); flat generation copies the template as before |
| noise terrain, 256 chunks in one batch (the generator, the join) | 0.23 ms per chunk | **2.2 to 2.8 ms** per chunk (about 10 times) |
| noise terrain, generation with light and packet (16 x 16 chunks) | 2.6 to 3.0 ms per chunk | 4.6 ms per chunk |
| one chunk at a time (`mc.compute_light`: the chunk and its 8 neighbours are read) | 0.2 ms | 5.9 ms |
| vanilla-like terrain (caves, lava, lichen, village), 612 chunks in one region | 0.36 to 0.42 ms per chunk | 13.7 ms per chunk |
| an edit (`mc.light_step`, one changed cell, noise terrain, steady state) | (no update existed) | 41 ms (a torch: block light only), 52 to 56 ms (stone placed or removed: sky and block); 70 ms when a section turns non-empty (3 x 3 chunks lit again) |
| a fill of 2,976 blocks over 3 chunks | | 1.1 to 1.5 s (the chunks around lit again) |

**The target "no more than 2 to 3 times the old model per chunk" is met for flat worlds and not for terrain**: 10 times on noise terrain, 34 times on vanilla-like terrain.  Where it goes: the masks of
a section (one `translate()` per class for the 4-bit palettes that are 90% of the sections: 0.25 ms; 5- and 6-bit palettes unpack their entries: 3.7 ms), about 14 SQL statements per kind for the waves
(2 ms each however little they do), 0.35 to 0.46 ms for the output array of every layer that holds light, and on vanilla terrain the 17 sections per chunk that lie within reach of a lava or lichen
cell (1,352 of 7,064 sections have an emitter in the palette).  Ideas not done: keep the section masks in a table keyed by the section's bytes (a section is unpacked once), cut the 5- and 6-bit
unpacking, merge the wave statements of the levels that have a front of a few sections, a cheaper plane spread.  The straight-down model is 10 to 30 times cheaper because it reads one
heightmap; it cannot see a cell of the chunk (water, leaves, an overhang, a lamp).

## Files

`sql/221_light_schema.sql` (tables, `mc.light_ready`), `222_light_masks.sql` (bit-string constants, section masks), `223_light_pack.sql` (planes <-> arrays), `224_light_solve.sql` (work
tables, waves, shapes), `225_light_region.sql` (`mc.light_region`), `226_light_api.sql` (flat test, `mc.light_chunks`, `mc.light_at`), `227_light_update.sql` (`mc.light_update`),
`228_light_step.sql` (queue, trigger, `mc.light_step`, packets); in-place edits of `sql/220` (the dispatcher), `sql/837` (one line), `sql/855` (the generator's light call).
`tools/gen_light.sh`, `tools/java/LightDump.java`, `tools/load_light.py`.  Tests: `tests/sql/221_light_engine.sql`, `tests/light/` (`compare_edits.py`, `vanilla_world.sh`,
`e2e_light.sh`), `tests/e2e/light_probe.py`, `tests/e2e/compare_light.py`.
