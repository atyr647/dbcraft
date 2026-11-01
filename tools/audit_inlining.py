#!/usr/bin/env python3
"""Audit which dbcraft functions the planner inlines.

usage: tools/audit_inlining.py [--md] [--json FILE] [--only-not-inlined] [--hot-stats FILE]
       tools/audit_inlining.py --check [--hot sql/INLINE_HOT.txt]
Connection: the usual libpq environment (PGHOST, PGPORT, PGUSER, PGDATABASE).

What it does
  * lists every function in schemas proto, mc, net, ref with language, volatility, STRICT, SECURITY DEFINER, parallel marking, SET clauses, result shape;
  * for every LANGUAGE sql function PROVES inlining empirically (tools/audit_inlining.sql: EXPLAIN VERBOSE of a call over a real table; the function's own
    name still in the plan means "not inlined"), then names the most likely reason;
  * --hot-stats FILE (CSV from tests/bench/inline/run_funcs.sh: function, calls per tick, ms per tick) ranks the not-inlined / plpgsql functions that a
    tick actually calls by (calls x per-call cost);
  * --check fails (exit 1) when a function listed in sql/INLINE_HOT.txt ("schema.name/nargs | why") is not inlined in the connected database.
"""
import csv, io, json, os, re, subprocess, sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
PSQL = os.environ.get("PSQL", "psql")

def psql_csv(args):
    p = subprocess.run([PSQL, "-X", "-q", "--csv", "-t", "-v", "ON_ERROR_STOP=1"] + args, capture_output=True, text=True)
    if p.returncode:
        sys.exit("psql failed: " + p.stderr.strip())
    return list(csv.reader(io.StringIO(p.stdout)))

STATIC = """
select p.oid, n.nspname || '.' || p.proname || '/' || p.pronargs as key, n.nspname || '.' || p.proname as name, p.pronargs,
       l.lanname, case p.provolatile when 'i' then 'immutable' when 's' then 'stable' else 'volatile' end,
       p.proisstrict, p.prosecdef, case p.proparallel when 's' then 'safe' when 'r' then 'restricted' else 'unsafe' end,
       coalesce(array_to_string(p.proconfig, ';'), ''), p.proretset, format_type(p.prorettype, null),
       coalesce(array_length(array_remove(array_remove(p.proargmodes, 'i'), 'v'), 1), 0) as n_out,
       length(p.prosrc), p.prokind
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace join pg_language l on l.oid = p.prolang
 where n.nspname in ('proto', 'mc', 'net', 'ref') and p.prokind in ('f', 'p')
 order by 1
"""
BODY = "select p.oid, p.prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace join pg_language l on l.oid = p.prolang where n.nspname in ('proto','mc','net','ref') and l.lanname = 'sql'"

def reason(f, body, vol):
    """The most likely reasons a LANGUAGE sql function is not inlined (PG16 inline_function / inline_set_returning_function).
    vol maps function names (bare and schema-qualified) to the set of volatility letters of every overload."""
    why = []
    if f["volatility"] == "volatile": why.append("volatile (a volatile function is never inlined)")
    if f["secdef"]: why.append("SECURITY DEFINER")
    if f["config"]: why.append("has SET clause(s)")
    if f["n_out"] and not f["retset"]: why.append("OUT parameters / record result without SETOF: the planner inlines only scalar or SETOF results")
    if f["rettype"] == "record" and not f["n_out"]: why.append("returns record")
    b = re.sub(r"--[^\n]*", "", body or "").strip().rstrip(";").strip()
    if ";" in b: why.append("several statements")
    if re.match(r"(?is)\s*with\b", b): why.append("starts with WITH (CTE): not a simple SELECT/expression")
    if not f["retset"] and re.search(r"(?is)\bfrom\b", b): why.append("scalar function whose body has a FROM clause (even a trivial subselect): only a pure expression is inlined")
    # IMMUTABLE (or STABLE) functions are not inlined when the body calls something less constant than they claim to be
    if f["volatility"] in ("immutable", "stable"):
        worse = set()
        for m in re.finditer(r"(?i)\b([a-z_][a-z_0-9]*(?:\.[a-z_][a-z_0-9]*)?)\s*\(", b):
            name = m.group(1).lower()
            if name in ("select", "case", "when", "then", "else", "end", "array", "row", "exists", "in", "and", "or", "not", "from", "where", "cast", "coalesce", "least", "greatest", "any", "all"): continue
            v = vol.get(name)
            if v and (("v" in v) or ("s" in v and f["volatility"] == "immutable")) and "i" not in v and (name != f["name"].lower()):
                worse.add(f"{name} ({'volatile' if 'v' in v else 'stable'})")
        if worse: why.append(f"declared {f['volatility'].upper()} but calls " + ", ".join(sorted(worse)) + f": mark it {'STABLE' if f['volatility'] == 'immutable' and not any('volatile' in w for w in worse) else 'less strict'} to allow inlining")
    if re.search(r"(?i)\b(count|sum|avg|min|max|array_agg|string_agg|bit_or|bool_or)\s*\(", b): why.append("aggregate in body")
    if re.search(r"(?i)\bover\s*\(", b): why.append("window function in body")
    if f["strict"]: why.append("STRICT (inlined only if the body is provably strict in every argument)")
    if f["retset"] and re.search(r"(?i)\border\s+by\b|\blimit\b|\bgroup\s+by\b", b): why.append("set-returning body with ORDER BY/LIMIT/GROUP BY (checked by the planner)")
    return "; ".join(why) or "unknown (read the PG16 source: functions.c / clauses.c inline_function)"

def load():
    st = psql_csv(["-c", STATIC])
    keys = ["oid", "key", "name", "nargs", "language", "volatility", "strict", "secdef", "parallel", "config", "retset", "rettype", "n_out", "srclen", "kind"]
    funcs = {}
    for r in st:
        d = dict(zip(keys, r))
        for k in ("strict", "secdef", "retset"): d[k] = d[k] == "t"
        d["n_out"] = int(d["n_out"]); d["nargs"] = int(d["nargs"]); d["srclen"] = int(d["srclen"])
        d["inlined"] = None; d["detail"] = ""; d["expensive"] = ""
        funcs[d["oid"]] = d
    bodies = {r[0]: r[1] for r in psql_csv(["-c", BODY])}
    vol = {}
    for r in psql_csv(["-c", "select lower(n.nspname || '.' || p.proname), lower(p.proname), p.provolatile from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname in ('pg_catalog','proto','mc','net','ref')"]):
        vol.setdefault(r[0], set()).add(r[2])
        if r[0].startswith("pg_catalog."): vol.setdefault(r[1], set()).add(r[2])
        else: vol.setdefault(r[0], set()).add(r[2])
    for r in psql_csv(["-f", os.path.join(ROOT, "tools", "audit_inlining.sql")]):
        d = funcs.get(r[0])
        if d is not None:
            d["inlined"] = {"inlined": True, "not_inlined": False}.get(r[3]); d["probe"] = r[3]; d["detail"] = r[4]; d["expensive"] = r[5] if len(r) > 5 else ""
    for d in funcs.values():
        d["reason"] = reason(d, bodies.get(d["oid"]), vol) if d.get("inlined") is False else ""
    return funcs

def check(funcs, hot):
    """sql/INLINE_HOT.txt lines:  schema.name/nargs | mode | why     mode: inline (inlinable with column/constant arguments), inline_any (also with an
    expensive argument expression), plpgsql (must stay PL/pgSQL: its call sites pass computed arguments, and a non-inlined SQL function re-plans its body in
    every statement execution)."""
    bykey = {d["key"].lower(): d for d in funcs.values()}
    bad = 0
    for line in open(hot):
        line = line.strip()
        if not line or line.startswith("#"): continue
        key, mode, *why = [p.strip() for p in line.split("|")]
        why = " | ".join(why)
        d = bykey.get(key.lower())
        if d is None: print(f"MISSING  {key}: not in the database (renamed? update {hot})"); bad = 1; continue
        if mode == "plpgsql":
            if d["language"] != "plpgsql": print(f"REGRESSED {key}: is {d['language']}, must be plpgsql  [{why}]"); bad = 1
            else: print(f"ok       {key} (plpgsql)")
        elif d["language"] != "sql": print(f"NOT SQL  {key}: {d['language']} functions are never inlined  [{why}]"); bad = 1
        elif d["inlined"] is not True: print(f"BLOCKED  {key}: the planner no longer inlines it ({d.get('probe', 'unprobed')}: {d['detail'] or d['reason'] or '?'})  [{why}]"); bad = 1
        elif mode == "inline_any" and d["expensive"] != "yes": print(f"CHEAP-ONLY {key}: inlined with column arguments but not with an expensive argument expression ({d['expensive']})  [{why}]"); bad = 1
        else: print(f"ok       {key} ({mode})")
    return bad

def hot_report(funcs, path, min_calls=1.5, min_ms=0.25):
    """Join a run_funcs.sh CSV with the audit: the functions a tick CALLS (so were not inlined) ranked by what they cost."""
    bykey = {}
    for d in funcs.values(): bykey[(d["name"], d["nargs"])] = d
    out = []
    for r in csv.DictReader(open(path)):
        d = bykey.get((r["name"], int(r["nargs"])))
        if d is None or r["name"].startswith(("tickbench.", "ibench.")): continue
        calls, total, selfms, us = float(r["calls_per_tick"]), float(r["total_ms_per_tick"]), float(r["self_ms_per_tick"]), float(r["self_us_per_call"] or 0)
        if calls < min_calls and total < min_ms: continue
        out.append((selfms, calls, total, us, d))
    out.sort(key=lambda x: -x[0])
    print(f"{'function':34s} {'lang':8s} {'vol':9s} {'calls/tick':>10s} {'self ms/tick':>12s} {'us/call':>9s}  inlinable?  why not")
    for selfms, calls, total, us, d in out:
        verdict = "n/a (plpgsql)" if d["language"] != "sql" else ("yes" if d["inlined"] else "NO")
        print(f"{d['name'] + '/' + str(d['nargs']):34s} {d['language']:8s} {d['volatility']:9s} {calls:10.1f} {selfms:12.3f} {us:9.1f}  {verdict:13s} {d['reason'] if d['inlined'] is False else ''}")

def main():
    funcs = load()
    if "--hot-stats" in sys.argv:
        hot_report(funcs, sys.argv[sys.argv.index("--hot-stats") + 1])
        return
    if "--check" in sys.argv:
        hot = sys.argv[sys.argv.index("--hot") + 1] if "--hot" in sys.argv else os.path.join(ROOT, "sql", "INLINE_HOT.txt")
        sys.exit(check(funcs, hot))
    rows = sorted(funcs.values(), key=lambda d: (d["name"], d["nargs"]))
    if "--json" in sys.argv:
        json.dump(rows, open(sys.argv[sys.argv.index("--json") + 1], "w"), indent=1)
    stats = {}
    if "--hot-stats" in sys.argv:
        for r in csv.reader(open(sys.argv[sys.argv.index("--hot-stats") + 1])):
            if r and r[0] != "name": stats[(r[0], int(r[1]))] = r
    cnt = {}
    for d in rows:
        k = d["language"] + ("/inlined" if d["inlined"] else "/not-inlined" if d["inlined"] is False else "/unprobed")
        cnt[k] = cnt.get(k, 0) + 1
    print("summary:", ", ".join(f"{k} {v}" for k, v in sorted(cnt.items())))
    if "--md" in sys.argv:
        print("\n| function | lang | volatility | strict | parallel | result | inlined | with expensive arg | why not |\n|---|---|---|---|---|---|---|---|---|")
        for d in rows:
            if "--only-not-inlined" in sys.argv and d["inlined"] is not False and not (d["inlined"] and d["expensive"] == "no" and "--with-cheap-only" in sys.argv): continue
            print(f"| {d['name']}/{d['nargs']} | {d['language']} | {d['volatility']} | {'y' if d['strict'] else ''} | {d['parallel']} | {'setof ' if d['retset'] else ''}{d['rettype']}{' (+%d out)' % d['n_out'] if d['n_out'] else ''} | "
                  f"{'yes' if d['inlined'] else 'NO' if d['inlined'] is False else 'n/a' if d['language'] != 'sql' else '?'} | {d['expensive'] if d['inlined'] else ''} | {d['reason']} |")
    else:
        for d in rows:
            if d["inlined"] is False or (d["language"] != "sql" and "--only-not-inlined" not in sys.argv):
                print(f"{d['name']}/{d['nargs']:<2} {d['language']:8s} {d['volatility']:9s} {'strict ' if d['strict'] else ''}{d['reason']}")

if __name__ == "__main__":
    main()
