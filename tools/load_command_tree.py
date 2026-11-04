#!/usr/bin/env python3
"""Load the command graph (mc.cmd_node) from a recording of a real vanilla server, so that the `commands` packet is GENERATED from rows.

usage: tools/load_command_tree.py [CAPTURE.jsonl]     default: play_op4 from $DBCRAFT_CAPTURES / $DBCRAFT_HOME/captures / tests/fixtures/captured
Connection: libpq environment or DBCRAFT_PSQL.   Exit status 3 (and a message) when the recording is missing; the database then keeps sending the
level-0 `commands` packet it has as a static packet (net.static_packet) to everybody.

What it reads: the `commands` packet an operator of level 4 receives (every node, in the order vanilla numbered them: breadth first from the root, children in
registration order).  Each node becomes a row: kind, name, flags, children, redirect, argument parser id and its serialized properties, suggestion provider.
What it adds: `min_level`, the permission level a player needs to see the node.  The packet cannot say that (it only lists what one viewer is allowed to see),
so it comes from the data generator's `commands.json` report (the `permissions` of each node, matched by path: gamemasters = 2, admins = 3, owners = 4).
The loader checks what it can: every node of the graph is found in the report, a node has the `restricted` flag exactly when the report gives it permissions,
the argument properties decode to the exact end of the packet.  tests/sql/810_command_tree.sql then regenerates the packet for each level and compares it with
the recordings (play_nocomp = level 0, play_op1 .. play_op4) byte for byte.  Mojang data is read from YOUR recording at load time and never committed.
"""
import json, os, struct, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _capture

LEVELS = {"moderators": 1, "gamemasters": 2, "admins": 3, "owners": 4}
path = sys.argv[1] if len(sys.argv) > 1 else (_capture.find_capture("play_op4") or "")
if not os.path.exists(path):
    print(f"load_command_tree: no recording of an operator's join ({path or 'play_op4.jsonl'}): the command tree stays the static level-0 packet", file=sys.stderr)
    sys.exit(3)
psql = os.environ.get("DBCRAFT_PSQL", "psql").split()
reports = os.environ.get("DBCRAFT_REPORTS", _capture.DEFAULT_REPORTS)


def vi(b, o):
    v = s = 0
    while True:
        c = b[o]; o += 1
        v |= (c & 127) << s
        if c < 128:
            return v, o
        s += 7


def string(b, o):
    n, o = vi(b, o)
    return b[o:o + n].decode(), o + n


def props_end(t, b, o):
    """End offset of the serialized properties of argument parser type t (ArgumentTypeInfos): flags + numbers, a string kind, a registry key ..."""
    if t in (1, 2, 3, 4):                                   # float double integer long: flags (1 min, 2 max) then the numbers
        w = {1: 4, 2: 8, 3: 4, 4: 8}[t]; f = b[o]; return o + 1 + w * (bool(f & 1) + bool(f & 2))
    if t == 5: return vi(b, o)[1]                           # string: 0 word, 1 phrase, 2 greedy
    if t in (6, 31): return o + 1                           # entity (single, players only), score_holder (multiple)
    if t == 43: return o + 4                                # time: minimum ticks
    if t in (44, 45, 46, 47, 48): return string(b, o)[1]    # resource_or_tag, resource_or_tag_key, resource, resource_key, resource_selector: registry key
    return o


packet = None
for line in open(path):
    r = json.loads(line)
    if r["name"] == "minecraft:commands" and r["dir"] == "clientbound":
        w = bytes.fromhex(r["hex"]); _, o = vi(w, 0); _, o = vi(w, o); packet = w[o:]; break
if packet is None:
    sys.exit(f"{path}: no commands packet")
arg_names = {v["protocol_id"]: k for k, v in json.load(open(os.path.join(reports, "registries.json")))["minecraft:command_argument_type"]["entries"].items()}
rep = json.load(open(os.path.join(reports, "commands.json")))

n, o = vi(packet, 0)
nodes = []
for i in range(n):
    f = packet[o]; o += 1
    nc, o = vi(packet, o); ch = []
    for _ in range(nc):
        c, o = vi(packet, o); ch.append(c)
    red = None
    if f & 8: red, o = vi(packet, o)
    name = None
    if f & 3: name, o = string(packet, o)
    at = props = sug = None
    if (f & 3) == 2:
        at, o = vi(packet, o); e = props_end(at, packet, o); props = packet[o:e]; o = e
    if f & 16: sug, o = string(packet, o)
    nodes.append(dict(id=i, kind=f & 3, executable=bool(f & 4), restricted=bool(f & 32), name=name, children=ch, redirect=red, argtype=at, props=props, sug=sug))
root_idx, o = vi(packet, o)
if o != len(packet) or root_idx != 0:
    sys.exit(f"{path}: the commands packet does not decode to its end ({o} of {len(packet)}), root {root_idx}")

# min_level: walk the graph from the root along the first path that reaches each node, following the report's tree by names
problems = []
seen = {0: (rep, 0)}
stack = [0]
level = {0: 0}
while stack:
    i = stack.pop(0)
    jn, inherited = seen[i]
    for c in nodes[i]["children"]:
        nd = nodes[c]
        jc = jn.get("children", {}).get(nd["name"])
        if jc is None:
            problems.append(f"node {c} {nd['name']!r} below {nodes[i]['name']!r} is not in commands.json")
            continue
        perm = jc.get("permissions")
        own = LEVELS[perm["permission"]["level"]] if perm else 0
        if bool(perm) != nd["restricted"]:
            problems.append(f"node {c} {nd['name']!r}: restricted flag {nd['restricted']} but permissions {perm}")
        if c not in seen:
            seen[c] = (jc, own); level[c] = own; stack.append(c)
        elif level[c] != own:
            problems.append(f"node {c} {nd['name']!r} reached twice with levels {level[c]} and {own}")
    # a redirect target is reached through its own parent as well; nothing to do for it here
unreached = [x["id"] for x in nodes if x["id"] not in level]
if unreached:
    problems.append(f"{len(unreached)} nodes not reached from the root, first {unreached[:5]}")
if problems:
    print("load_command_tree: the recording and commands.json disagree:", file=sys.stderr)
    for p in problems[:20]: print("  " + p, file=sys.stderr)
    sys.exit(1)

def lit(s): return "null" if s is None else "'" + s.replace("'", "''") + "'"
rows = []
for x in nodes:
    rows.append("(%d,%d,%s,%s,%s,%s,%s,%s,%s,%s,%d)" % (
        x["id"], x["kind"], lit(x["name"]), str(x["executable"]).lower(), str(x["restricted"]).lower(),
        "null" if x["redirect"] is None else x["redirect"],
        "null" if x["argtype"] is None else x["argtype"], "null" if x["argtype"] is None else lit(arg_names[x["argtype"]]),
        "null" if x["props"] is None else "'\\x%s'::bytea" % x["props"].hex(), lit(x["sug"]), level[x["id"]]))
kids = "".join(f"insert into mc.cmd_child (parent, pos, child) values ({x['id']},{p},{c});" for x in nodes for p, c in enumerate(x["children"], 1))
sql = ("truncate mc.cmd_child, mc.cmd_node, mc.cmd_tree_cache;"
       "insert into mc.cmd_node (id, kind, name, executable, restricted, redirect, argtype, argtype_name, argprops, suggestions, min_level) values "
       + ",".join(rows) + ";" + kids + "select mc.cmd_tree_rebuild();")
p = subprocess.run(psql + ["-X", "-q", "-v", "ON_ERROR_STOP=1"], input=sql.encode(), capture_output=True)
if p.returncode:
    sys.exit(p.stderr.decode())
print(f"loaded the command graph: {len(nodes)} nodes, {sum(len(x['children']) for x in nodes)} edges, {len(nodes[0]['children'])} commands, from {path}")
