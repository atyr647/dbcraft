# Chunk compression

Online mode requires encryption (AES-CFB8) but not compression.  They are independent; compression is a separate, optional layer.
Measured on **synthetic** chunks (`tests/bench/chunk_compression.py`: sine-noise terrain, 24 sections, light arrays, heightmap filler).
Real vanilla chunks will differ; re-measure on imported worlds.

| Chunk payload | raw | zlib L6 | ratio | RLE-only deflate | ratio |
|---|---|---|---|---|---|
| flat world | 110.9 KiB | 6.3 KiB | 17.6x | 6.6 KiB | 16.8x |
| rolling terrain with ores | 124.9 KiB | 9.7 KiB | 12.9x | 11.3 KiB | 11.0x |

Huffman-only (no matching) gets just 5.4-5.6x, so most of the gain is repeated runs, which a very simple encoder finds.

## Why compress

* A joining player at view distance 10 loads 441 chunks: about 55 MB raw, about 4-5 MB compressed.
* AES-CFB8 costs one AES block per byte, so compressing first cuts encryption work by the same 11-18x.
* Vanilla compresses every packet again for every player.  Here the compressed packet is identical for all players, so it is made once.

## Design

1. **Compress once, cache in the database.**  The cache table holds the finished, framed, compressed packet.  The gateway only encrypts and sends it.
2. **Per-section fragments.**  Each dirty 16x16x16 section is compressed to its own deflate fragment, ended with a sync flush so it is byte-aligned.
   A chunk packet is the concatenation of fragments.  The zlib header and the Adler-32 trailer are assembled in SQL
   (Adler-32 values of pieces combine arithmetically from their lengths).  An edit recompresses one section, not a chunk.
   Not yet verified: that the vanilla client accepts this stream.  It is a valid deflate stream, and the differential harness will check it.
3. **Compressor, two options.**
   * Pure SQL: an RLE plus fixed-Huffman encoder in PL/pgSQL.  Expected 85-95% of zlib's ratio (from the RLE-only row above).
     Estimated 1-3 ms per 4 KB section from the loop speed measured below.  **Not written or measured yet.**
   * A small native `deflate(bytea)` function in a C extension (about 0.1 ms per section, estimated from zlib timings).  Fallback if SQL is too slow.
4. **Gateway.**  It compresses nothing.  Serverbound packets over the threshold are compressed by the client, so the gateway needs an inflate-only path (rare, small).

## Postgres detail found while measuring: large `bytea` loops are quadratic

`get_byte` on a large value copies (detoasts) the whole value on every call.

| Loop over bytes | Time per byte |
|---|---|
| 128 KB values (compressed or `STORAGE EXTERNAL`) | 10.8 us / 9.4 us |
| 4 KB values kept inline | 0.24 us |

So each section must stay a small, inline `bytea`: `STORAGE MAIN` and a raised `toast_tuple_target` (up to 8160) so sections of up to about 8 KB are not moved out of line.
Assemble the large packet only at the end, with one concatenation.
