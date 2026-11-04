#!/usr/bin/env python3
"""execution cost of the stages of mc.entity_auto_run (prepared statements, generic plans): writes a psql script
usage: tests/bench/mobs2/stages.py | PGDATABASE=... psql -X -q -At      (on the population a bench.sql run left; ticks continue the clock)"""
s = open('sql/940_entity_auto_lanes.sql').read()
a = s.index("    with s as materialized (", s.index("create or replace function mc.entity_auto_run"))
b = s.index("    ), upd as (", a)
body = s[a:b].replace("    with s as materialized (", "with s as materialized (", 1)
body = body.replace("p_ids is null", "true").replace("p_ids is not null", "false").replace("any(p_ids)", "any('{}'::int[])").replace("p_tick", "$1::bigint").replace("wp", "0.6")
print("select coalesce(last_tick, 0) + 1 as t from mc.entity_clock \\gset")
for st in ["s", "g", "w", "w2", "v"]:
    print("prepare st_%s(bigint) as\n%s\n) select count(*) from %s;" % (st, body, st))
print("\\timing on")
for st in ["s", "g", "w", "w2", "v"]:
    # the slot ticks: 8 consecutive ticks (every lazy lane is in some slot)
    print("\\echo stage %s" % st)
    for k in range(10):
        print("execute st_%s(:t + %d);" % (st, k))
