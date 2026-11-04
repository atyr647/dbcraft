"""Decode a `commands` packet body into a canonical form that does not depend on the order vanilla chose where it chooses by hash.

The real server builds the children of /gamerule in an order that differs from run to run (a hash order, like the registries); everything else in the graph is in
registration order.  canonical() returns one string per graph: the nested structure from the root with the children of /gamerule sorted by name and redirects written
as the path of their target, so two runs of the real server (and dbcraft) give the same string.
"""
import hashlib, sys


def _vi(b, o):
    v = s = 0
    while True:
        c = b[o]; o += 1; v |= (c & 127) << s
        if c < 128: return v, o
        s += 7


def _string(b, o):
    n, o = _vi(b, o); return b[o:o + n].decode(), o + n


def _props_end(t, b, o):
    if t in (1, 2, 3, 4):
        w = {1: 4, 2: 8, 3: 4, 4: 8}[t]; f = b[o]; return o + 1 + w * (bool(f & 1) + bool(f & 2))
    if t == 5: return _vi(b, o)[1]
    if t in (6, 31): return o + 1
    if t == 43: return o + 4
    if t in (44, 45, 46, 47, 48): return _string(b, o)[1]
    return o


def decode(body):
    n, o = _vi(body, 0); nodes = []
    for _ in range(n):
        f = body[o]; o += 1; nc, o = _vi(body, o); ch = []
        for _ in range(nc): c, o = _vi(body, o); ch.append(c)
        red = None
        if f & 8: red, o = _vi(body, o)
        name = None
        if f & 3: name, o = _string(body, o)
        at = props = sug = None
        if (f & 3) == 2:
            at, o = _vi(body, o); e = _props_end(at, body, o); props = body[o:e]; o = e
        if f & 16: sug, o = _string(body, o)
        nodes.append(dict(flags=f, children=ch, redirect=red, name=name, argtype=at, props=props, sug=sug))
    return nodes


def canonical(body):
    nodes = decode(body)
    # the path (by names, through children) at which each node is first met, breadth first
    path = {0: ""}; queue = [0]
    for i in queue:
        for c in nodes[i]["children"]:
            if c not in path: path[c] = path[i] + "/" + str(nodes[c]["name"]); queue.append(c)
    memo = {}

    def rec(i):
        if i in memo: return memo[i]
        nd = nodes[i]; kids = list(nd["children"])
        if nd["name"] == "gamerule" and path.get(i) == "/gamerule": kids.sort(key=lambda c: nodes[c]["name"])
        s = "(%d|%s|%s|%s|%s|%s|[%s])" % (nd["flags"], nd["name"], nd["argtype"], nd["props"].hex() if nd["props"] is not None else "", nd["sug"],
                                          path.get(nd["redirect"]) if nd["redirect"] is not None else "", ",".join(rec(c) for c in kids))
        memo[i] = s
        return s
    sys.setrecursionlimit(10000)
    return hashlib.md5(rec(0).encode()).hexdigest() + ":" + str(len(nodes))
