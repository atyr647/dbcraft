# dlcraft shared specification

Both implementations (Datalevin in `src/dlcraft/`, PostgreSQL in `pg/`) do **the same work** and must produce **byte-identical outputs**.
Everything here is exact: integer arithmetic only where it feeds a hash; IEEE doubles elsewhere (same in Java and PostgreSQL `float8`).
The harness (`bench/`) drives both from the same deterministic inputs and compares digests before it trusts any timing.

There is one dimension (the overworld), `min_y = -64`, `height = 384` (sections `sy = -4 .. 19`, `sy = y >> 4` arithmetic).
Coordinates `x, y, z` are absolute block coordinates, chunk `cx = x >> 4`, `cz = z >> 4`.  Section index of a block: `idx = ((y & 15) << 8) | ((z & 15) << 4) | (x & 15)`.

## 1. Block states (the experiment's own ids; not Mojang's)

| id | name | id | name |
|---|---|---|---|
| 0 | air | 11 | water[level=5] |
| 1 | stone | 12 | water[level=6] |
| 2 | grass_block | 13 | water[level=7] |
| 3 | dirt | 14 | gravel |
| 4 | bedrock | 15 | coal_ore |
| 5 | sand | 16 | iron_ore |
| 6 | water[level=0] (source) | 17 | diamond_ore |
| 7..10 | water[level=1..4] | 18 | cobblestone |
|  |  | 19 | gold_block |
|  |  | 20 | oak_planks |

`is_water(s) = 6 <= s <= 13`, `water_level(s) = s - 6`.  Air is 0 (the only air).

## 2. Section wire format

A section is stored and shipped as (palette, bits, packed longs) in Minecraft's wire layout.

* `bits`: `0` if the palette has exactly one entry, else `max(4, ceillog2(palette_size))` (palette size <= 21, so `bits` is 0, 4 or 5).
* Packing (vanilla SimpleBitStorage): `vpl = 64 / bits` (integer division) entries per long; entry `i` lives in long `i / vpl` at bit offset `(i % vpl) * bits` (LSB first),
  entries never straddle two longs; each long is written **big-endian**; the number of longs is `ceil(4096 / vpl)`.  `bits = 0`: no data.
* `block_count` = number of entries whose state is not 0.

**Section blob** (what a chunk packet carries per section), byte exact:

```
u16 block_count (big-endian)
block container:  u8 bits
                  bits == 0 : varint(palette[0])
                  bits  > 0 : varint(len(palette)), then varint(palette[i]) for each i, then the packed longs
biome container:  0x00 0x00          (bits 0, single value 0)
```

VarInt is the Minecraft one (7 bits per byte, LSB group first, high bit = continue; values here are < 2^31, non-negative).

**Chunk payload** = the 24 section blobs for `sy = -4 .. 19`, concatenated in that order.
**Chunk packet** = `varint(len(body)) || body`, `body = 0x2c || i32be(cx) || i32be(cz) || payload`.

## 3. Palette rules (so that stored bytes agree)

* Generated section: palette = the distinct states present, **sorted ascending**.
* `set_block` / bulk edits: if the new state is not in the palette it is **appended**; if the palette then exceeds `2^bits` entries (or `bits` was 0) the section is repacked with `bits = max(4, ceillog2(size))`;
  entries are remapped by palette *index*, existing indices never change; the palette never shrinks or reorders.  A change that leaves the state equal is a no-op.
* `fill` covering a whole section (all 4096 blocks): the section becomes `palette = [state]`, `bits = 0`.  A partial fill is a normal edit (append, repack if needed).
* `block_count` is maintained exactly.
* A `set_block`, `set_blocks` or `fill` that changes **no** block of a section leaves that section byte for byte untouched (no palette append, no collapse of a whole-section fill, no version bump, no event).
  For `set_blocks`, a palette entry is appended only when an edit actually changes a block (checked against the section as already modified by earlier edits of the same call).

## 4. Terrain generator (integers only)

```
hash2(a, b, s) = h0 = (a*374761393 + b*668265263 + s*1274126177) & 0x7fffffff       -- 64-bit signed arithmetic, two's complement &
                 h1 = ((h0 ^ (h0 >> 13)) * 1274126177) & 0x7fffffff
                 return h1 ^ (h1 >> 16)                                                -- 0 <= result < 2^31
oct(x, z, shift, seed):  c = 1 << shift;  gx = x >> shift;  gz = z >> shift;  fx = x & (c-1);  fz = z & (c-1)
                         n00 = hash2(gx,  gz,  seed) & 4095;   n10 = hash2(gx+1, gz,  seed) & 4095
                         n01 = hash2(gx,  gz+1, seed) & 4095;   n11 = hash2(gx+1, gz+1, seed) & 4095
                         return (n00*(c-fx)*(c-fz) + n10*fx*(c-fz) + n01*(c-fx)*fz + n11*fx*fz) >> (2*shift)      -- 0..4095
height(x, z) = 52 + ((oct(x, z, 6, 1337) * 32) >> 12) + ((oct(x, z, 4, 1338) * 10) >> 12)                         -- 52..93
```

`block_at(x, y, z)` with `h = height(x, z)`:

```
y == -64                      -> 4 bedrock
y > h                         -> 6 (water source) if y <= 62 else 0
y == h                        -> 5 sand if h <= 63 else 2 grass_block
h-3 <= y <= h-1               -> 5 sand if h <= 63;  else 14 gravel if (y == h-1 and (hash2(x, z, 7) & 31) == 0);  else 3 dirt
otherwise (stone zone)        r = hash2(x + y*4099, z - y*7919, 11) % 1024
                              r < 10 -> 15 coal_ore;  10 <= r < 15 and y < 32 -> 16 iron_ore;  r == 15 and y < -16 -> 17 diamond_ore;  else 1 stone
```

`gen_chunk(cx, cz)` creates all 24 sections of the chunk (all-air sections are stored too, as `palette=[0], bits=0, block_count=0`) with the section rules of §3, and a chunk record with `version = 0`.
Generating a chunk that exists is a no-op.  A block of a chunk that has not been generated reads as air and cannot be set.

## 5. World API (both engines)

| operation | semantics |
|---|---|
| `get_block(x,y,z) -> state` | air if the chunk is not generated or `y` outside `[-64, 319]` |
| `set_block(x,y,z,state) -> bool` | false (no change) if the chunk is missing, `y` out of range, or the state is already there. On change: §3 palette rules, `block_count`, `chunk.version += 1`, and **one block event** `(x,y,z,old,new)` is appended to the block-event queue |
| `set_blocks(xs,ys,zs,states)` | bulk form: applies the changes **in array order** but reads/writes each section once; per changed block one block event (array order); `chunk.version += 1` once per call per chunk with a change; returns the number changed |
| `fill(x1,y1,z1,x2,y2,z2,state) -> n` | inclusive box (corners in any order) clipped to the generated world; n = blocks changed; **one block event per touched section** with `kind = fill`: `(x,y,z)` = the lowest corner of (box ∩ section), `old = -1`, `new = state`, `count = changed blocks in that section` (sections where nothing changed emit nothing); `chunk.version += 1` once per chunk with a change |
| `chunk_payload(cx,cz)`, `chunk_packet(cx,cz)` | §2; `chunk_packet` is cached per `(cx,cz)` with the chunk version it was built from and rebuilt when stale (null/absent if the chunk does not exist) |
| `world_hash()` | `sha256` over, in `(cx, cz, sy)` numeric order, `i32be(cx) i32be(cz) i16be(sy) || section blob` for every section of every chunk |
| `count_states(x1,z1,x2,z2) -> (state, n)` | number of blocks per state over all `y`, columns `x1<=x<=x2, z1<=z<=z2`, generated chunks only (ungenerated count nothing); only states with n > 0 |
| `find_state(state, x1,z1,x2,z2) -> (x,y,z)*` | every position holding `state` in that column box, ordered by `(x, y, z)` |

## 6. Tick (players, visibility, packets)

Players: `eid = conn = 1..N`, `uuid = MD5(utf8("p" + eid))` (16 raw bytes), name `"bot" + eid`.  Per player: `x,y,z` (float8), `yaw,pitch` (float4), `on_ground`, `chunk_x = floor(x/16)`, `chunk_z = floor(z/16)`,
`sent_qx/qy/qz` (bigint, what other clients were last told: `rint(x*4096)` etc., round half to even), `last move tick`.
`join_bulk(eids, xs, ys, zs)` creates players with `yaw = pitch = 0`, `on_ground = true`, `sent_q = rint(pos*4096)`; **no packets**.
`vis_init()` computes the visible set silently: unordered pair `{P,Q}` is **visible** iff `(Px-Qx)^2 + (Pz-Qz)^2 <= 2304.0` (horizontal, 48 blocks; double arithmetic: `dx*dx + dz*dz`).  Stored as both directions.

**Inbox packet** (serverbound `move_player_pos_rot`), one per moving player per tick, 34 bytes:
`0x1d (VarInt, one byte) || f64be x || f64be y || f64be z || f32be yaw || f32be pitch || u8 flags` (bit 0 = on_ground).  `inbox_push(conn[], payload[])`.

**`server_tick()`** advances `game_time += 1` and does, in this order, using the tick number `t = game_time` after increment:

1. *Parse and validate.* For each inbox row (conn, payload): decode; if the conn is unknown or `|x - old_x| > 10` or `|z - old_z| > 10` (a move packet is rejected: no state change, no packets, but it is consumed) skip it.
   If a conn has several packets only the **last** (by arrival) counts.  The inbox is emptied.
2. *Apply* all accepted moves (x,y,z,yaw,pitch,on_ground; recompute `chunk_x/z`).  Let `M` = set of moved players.  From now on distances use the **final** positions of everyone.
3. *Visibility diff.* For every unordered pair `{P,Q}` with `P in M`, `Q` any other player (each pair once, even if both moved): `now = (dx*dx + dz*dz <= 2304.0)`, `was` = pair in the visible set.
   * `now and not was` (enter): insert both directions; packets `add_entity(Q) -> conn P` and `add_entity(P) -> conn Q` (positions are final).
   * `was and not now` (leave): delete both directions; packets `remove_entities(Q) -> conn P`, `remove_entities(P) -> conn Q`.
   Only pairs where at least one member moved can change, so only those are evaluated (an implementation may use any spatial index, as long as every pair within range is found).
4. *Movement fan-out.* For each `P in M`: `qx = rint(x*4096)`, `qy`, `qz` likewise; `dx = qx - sent_qx` etc.  For every `Q` such that the pair was **visible before and is visible now** (retained) send to `conn Q`:
   `move_entity` if `|dx|,|dy|,|dz| <= 32767` else `teleport_entity`.  Then `sent_q = q` for P (whether or not anyone saw it).
5. *Block events.* For every row of the block-event queue in order of event id (then the queue is emptied): for each player with `|chunk_x - ecx| <= 8` and `|chunk_z - ecz| <= 8`
   (`ecx = x>>4`, `ecz = z>>4` of the event) send `block_update` (kind block) or `fill_update` (kind fill) to its conn.
6. `game_time` is the only other state written.

**Clientbound frames** (each outbox row is `(conn int, data bytea)`, `data = varint(len(body)) || body`, `body = varint(packet_id) || fields`; all multi-byte numbers big-endian):

| packet | id | fields |
|---|---|---|
| `add_entity` | 0x01 | varint eid, 16 bytes uuid, f64 x, f64 y, f64 z, u8 yaw_angle, u8 pitch_angle |
| `remove_entities` | 0x02 | varint 1, varint eid |
| `move_entity` | 0x03 | varint eid, i16 dx, i16 dy, i16 dz, u8 yaw_angle, u8 pitch_angle, u8 on_ground (1/0) |
| `teleport_entity` | 0x04 | varint eid, f64 x, f64 y, f64 z, u8 yaw_angle, u8 pitch_angle, u8 on_ground |
| `block_update` | 0x05 | i64 pos, varint new_state |
| `fill_update` | 0x06 | i64 pos, varint new_state, varint count |

`pos = ((x & 0x3FFFFFF) << 38) | ((z & 0x3FFFFFF) << 12) | (y & 0xFFF)` (64-bit), `angle(deg) = floor(deg * 256.0 / 360.0) & 255` computed on `deg` converted to double (yaw/pitch are float4 on the wire and in storage).

`outbox_drain() -> (conn, data)*` returns and removes every row.  **Digest** (computed by the harness, order independent): for each row
`h = first 8 bytes of sha256(i32be(conn) || data)` as a signed big-endian long; digest = `(row count, total bytes, xor of all h)`.

## 7. Dynamics

Scheduled-tick queue of `(due bigint, x, y, z)`, `sched_add(due,x,y,z)` (duplicates allowed), `dyn_step(now) -> changed`:

1. Take (and delete) every queue entry with `due <= now`; let `D` be its distinct positions.
2. Reading the **pre-step** world only: for each `p in D` whose state is water with level `L = water_level` produce candidates
   `(n, L+1)` for each horizontal neighbour `n` (x±1, z±1, same y) holding air if `L+1 <= 7`, and `(p + (0,-1,0), 1)` if the block below `p` is air (y > -64).
3. For each distinct candidate position keep the **minimum** level; set the block to `6 + level` (a normal `set_blocks` with events, in `(x, z, y)` order) and `sched_add(now + 5, position)`.
4. Return the number of blocks set.

`random_ticks(now, cx0,cz0,cx1,cz1) -> changed`: for every existing section with `block_count > 0` in the chunk rectangle (inclusive) and `k in 0..2`:
`i = hash2(cx*64 + sy + 4, cz, now*3 + k) & 4095`; position `(cx*16 + (i & 15), sy*16 + (i >> 8), cz*16 + ((i >> 4) & 15))`.  Rule, evaluated against the **pre-state** for all picks: a dirt block (3) whose block above is air and that has a grass block (2)
horizontally adjacent (x±1, z±1, same y) becomes grass.  Apply all changes with `set_blocks` in `(cx, cz, sy, k)` order (duplicate picks of one block change it once); return the number changed.

## 8. Chat and inventory

`chat_add(sender int, msg text, at bigint) -> id` (ids 1, 2, 3, ... in insertion order).  `chat_search(word, limit)` = ids of messages containing `word` as a whole lower-case token (messages contain only
`[a-z0-9 ]`, tokens split on spaces, no stemming, no stop words), newest first.  `chat_recent(limit)` = newest `limit` ids.  `chat_count_by_sender()` = `(sender, n)`.

Inventory: slots 0..45, `max_stack(item) = 64` for item `< 100`, `16` for `100 <= item < 180`, `1` otherwise.  `inv_seed(n_players)` gives each player `p in 1..n` the slots 5..44 where `hash2(p, slot, 9) % 100 < 70`:
`item = 1 + hash2(p, slot, 10) % 199`, `count = 1 + hash2(p, slot, 11) % max_stack(item)`.  `inv_click(player, op, a, b)`:

* `swap` / `merge` with `a = b` are no-ops (so are all ops on an empty slot `a`, except `swap`, which exchanges two possibly empty slots; swapping two empty slots changes nothing).
* `swap`: exchange slots a and b.
* `merge`: if both hold the same item, move `min(count_a, max_stack - count_b)` from a to b (a becomes empty at 0); otherwise swap.  Empty a is a no-op.
* `quick`: shift-click slot `a`; target range = `36..44` if `a <= 35` (and `a >= 9`), `9..35` if `a` in `36..44`, nothing otherwise.  Pass 1: for target slots ascending, merge into slots holding the same item with room; pass 2: first empty target slot ascending takes the rest (up to max_stack).  The remainder stays in a.
* `drop`: remove `min(b, count_a)` items from slot a.

`inv_load(player) -> (slot, item, count)*` (non-empty slots, ascending).  `inv_digest() -> bigint` = `sum(player*1000003 + slot*8191 + item*131 + count*7 + player*slot*3)` over every non-empty slot.
