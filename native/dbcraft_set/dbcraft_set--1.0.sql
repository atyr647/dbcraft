-- dbcraft_set 1.0.  Pure functions: same input, same output, no I/O, no state.
\echo Use "CREATE EXTENSION dbcraft_set" to load this file. \quit

-- The keys (0 .. 65535) in the iteration order of a fastutil 8.5.18 ShortOpenHashSet that they were added to in this order.
CREATE FUNCTION dbcraft_set.shortset_order(keys int4[]) RETURNS int4[]
    AS 'MODULE_PATHNAME', 'dbs_shortset_order' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

-- The template (five characters per entry, see sql/960) and the finished air entries of a 512-byte 'cells' bit map: the changed positions of one section in a fill.
CREATE FUNCTION dbcraft_set.fill_tpl(cells bytea) RETURNS text
    AS 'MODULE_PATHNAME', 'dbs_fill_tpl' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION dbcraft_set.fill_tpl0(cells bytea) RETURNS text
    AS 'MODULE_PATHNAME', 'dbs_fill_tpl0' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
