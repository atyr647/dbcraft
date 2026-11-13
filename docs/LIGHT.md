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
| `mc.light_step(tick)` (`sql/228`), one line in `mc.tick_core` (`sql/837`) | empties the queue: cells -> `mc.light_update` (fills of more than 64 cells and whole sections: `mc.light_region` of the chunks around), new `mc.chunk.version` for chunks whose light changed, `light_update` packets for the connections for which the chunk is on the border of their view (`net.conn.view_cx/cz`, radius `view-distance + 1`) |
| `mc.light_at(dim, x, y, z, 'sky' or 'block')` | the stored light of one cell |

The marks of a packet (`mc.light_marks`): a changed section, and every neighbouring section (also over edges and corners) that a changed cell touches at the section's border: what
`aroundAndAtBlockPos` adds for a written cell.

## Evidence

*(numbers filled in from the runs listed in the last section)*

## What is exact, what is approximate

**Exact** (checked against the real server, see Evidence): sky and block light of imported vanilla terrain, cell for cell, including villages (shapes), caves, water, leaves, lava
and glow lichen; the light after edits (torches, glowstone, sea lanterns, shafts, roofs, pillars put up and removed, lava, slabs, stairs, leaves, a 31 x 16 x 6 fill), array by
array; the `light_update` packets of 14 of 15 edit steps (same chunks, same layers, same arrays), the 15th differing by a test-setup artefact described below.

**Approximate or not done:**

* **All-zero `data` arrays.**  Vanilla sometimes holds a layer as an allocated array of zeros (light that was there during generation and was cleared; light removed by an
  edit) and sends it as `data`; a layer computed from the blocks alone cannot know that and is `empty` (6 of 5,064 layers in the imported comparison).  After an edit the layer's
  stored form is kept, which is vanilla's behaviour.  Both forms mean the same light.
* **Which sections a `light_update` marks.**  Vanilla marks every section where a cell was *written*, including cells that its decrease wave set to 0 and the increase wave set
  back to the same value; this engine marks sections with a cell whose value changed (and the neighbours those touch).  They agree in the 15 recorded scenarios; a removal that
  clears and relights equal values (two torches whose light overlaps) can mark one section more in vanilla.  Not recorded.
* **Timing.**  The step runs once per tick from `mc.tick_core`: the light of a block change made while the tick's packets are handled (player breaks and places) is computed in the
  next tick and its `light_update` sent then; vanilla's engine is asynchronous and the packet comes in the same or the next tick.  The comparison above is per edit, not per tick.
* **Chunks next to missing chunks.**  Vanilla only completes a chunk whose neighbours exist.  Here a chunk is lit with the neighbours that exist; when a neighbour is created later the
  chunk is lit again and its version bumped (a new send is right), but a client that already holds it gets no `light_update` for that.  Imported worlds and flat worlds do not hit this.
* **Layers created or removed** (a first block in an empty section, the last block removed) light the three chunks again and vanilla's extra `light_update` marks for the new layers are not sent.
* **Sky light in other dimensions** (no sky light in the Nether, a ceiling in the End): only the overworld exists.
* The change filter is also not applied to chunks that are not "ticking" in vanilla (a chunk at the border of the view that the simulation distance does not reach: vanilla's
  `getTickingChunk()` is null and it sends nothing); the recorded setup (simulation distance 2, view distance 2) sent border updates, so border chunks were ticking there.

## Costs

*(measured, filled in below)*

## Files

`sql/221_light_schema.sql` (tables, `mc.light_ready`), `222_light_masks.sql` (bit-string constants, section masks), `223_light_pack.sql` (planes <-> arrays), `224_light_solve.sql` (work
tables, waves, shapes), `225_light_region.sql` (`mc.light_region`), `226_light_api.sql` (flat test, `mc.light_chunks`, `mc.light_at`), `227_light_update.sql` (`mc.light_update`),
`228_light_step.sql` (queue, trigger, `mc.light_step`, packets); in-place edits of `sql/220` (the dispatcher), `sql/837` (one line), `sql/855` (the generator's light call).
`tools/gen_light.sh`, `tools/java/LightDump.java`, `tools/load_light.py`.  Tests: `tests/sql/221_light_engine.sql`, `tests/light/` (`compare_edits.py`, `vanilla_world.sh`,
`e2e_light.sh`), `tests/e2e/light_probe.py`, `tests/e2e/compare_light.py`.
