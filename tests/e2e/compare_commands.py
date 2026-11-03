#!/usr/bin/env python3
"""Compare, step by step and player by player, what dbcraft sent while tests/e2e/cmd_probe.py ran a command session with what the REAL vanilla 26.3 server sent for
the same session.

usage: tests/e2e/compare_commands.py VANILLA_PREFIX OURS_PREFIX [--steps cmd_steps.py] [-v]     (prefixes of the files cmd_probe.py wrote: <prefix>_<Player>.jsonl)

Compared byte for byte, in order: the packets this layer is responsible for - system_chat, disguised_chat, commands, change_difficulty, player_abilities, the
game mode game_event (event 3), the permission-level entity_event (24..28) and container_set_slot.  Everything else vanilla sends (entity metadata, sounds,
item entities, recipe book, waypoints ...) is outside the layer and not compared.  What may legitimately differ is masked:
  * values of the run: the world seed, clock totals, game times, positions of players (each server places a joiner differently) - the text is masked, the shape is not
  * container_set_slot state ids and sequences are compared as they are
Exit status 0 when every step matches.
"""
import importlib.util, json, os, re, struct, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mcclient as m
import cmdtree

args = [a for a in sys.argv[1:] if not a.startswith("-")]
verbose = "-v" in sys.argv
van_p, our_p = args[0], args[1]
steps_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cmd_steps.py")
if "--steps" in sys.argv: steps_file = sys.argv[sys.argv.index("--steps") + 1]
spec = importlib.util.spec_from_file_location("cmd_steps", steps_file); S = importlib.util.module_from_spec(spec); spec.loader.exec_module(S)
MASK = getattr(S, "MASK", {})          # {step substring: "shape" (only the kinds of packets must agree) or [regex to blank out of the hex]}
SURVIVAL = "--survival" in sys.argv
NEEDS_SURVIVAL = getattr(S, "NEEDS_SURVIVAL", ())

KINDS = {"system_chat", "disguised_chat", "commands", "change_difficulty", "player_abilities", "game_event", "entity_event", "container_set_slot"}

def body(e):
    b = bytes.fromhex(e["hex"]); _, o = m.parse_varint(b, 0); _, o = m.parse_varint(b, o); return b[o:]

def relevant(e):
    n = e["name"].replace("minecraft:", "")
    if n not in KINDS: return False
    b = body(e)
    if n == "game_event": return b[0] == 3                      # game mode change only (weather events are gradual in vanilla, unmodelled)
    if n == "entity_event": return 24 <= b[-1] <= 28            # the player's permission level
    return True

def load(prefix, who):
    steps, cur = [], None
    for line in open(f"{prefix}_{who}.jsonl"):
        e = json.loads(line)
        if e["state"] == "mark": cur = (e["name"], []); steps.append(cur)
        elif cur is not None and e["dir"] == "clientbound" and relevant(e): cur[1].append(e)
    return steps

players = [p for p in S.PLAYERS if os.path.exists(f"{van_p}_{p}.jsonl") and os.path.exists(f"{our_p}_{p}.jsonl")]
V = {p: load(van_p, p) for p in players}; O = {p: load(our_p, p) for p in players}

# a readable form for the report (the text of a component, flattened)
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))) + "/tools")
import nbt_dump
def describe(e):
    n = e["name"].replace("minecraft:", ""); b = body(e)
    try:
        if n in ("system_chat", "disguised_chat"):
            text, _ = nbt_dump.dump(b, 0); return f"{n} {re.sub(r'[ ]*[\n][ ]*', ' ', text)}"[:600]
    except Exception: pass
    return f"{n} {b.hex()[:80]}"

def _string_root(e):
    b = body(e)
    if b[:1] == b"\x08": n = struct.unpack(">H", b[1:3])[0]; return b[3:3 + n].decode("utf-8", "replace")
    return None

def masked(e, label):
    n = e["name"].replace("minecraft:", "")
    if n == "commands": return "commands:" + cmdtree.canonical(body(e))          # the order of /gamerule's children is a hash order (differs per run of the real server)
    if n == "system_chat":
        t = _string_root(e)
        if t is not None and t.startswith("/gamerule ("):           # /help: the alternatives of /gamerule in that same hash order
            return "help:/gamerule (" + "|".join(sorted(t[len("/gamerule ("):-1].split("|"))) + ")"
    h = e["hex"]
    for key, pats in MASK.items():
        if label.endswith(": " + key) or label.endswith(" " + key):
            if pats == "shape": return e["name"]
            txt = h
            for p in pats: txt = re.sub(p, "", txt)
            return txt
    return h

checks = fails = skipped = unsupported = packets = 0
for p in players:
    for (lv, ev), (lo, eo) in zip(V[p], O[p]):
        if lv != lo: print(f"step mismatch {lv!r} {lo!r}"); sys.exit(2)
        if not SURVIVAL and any(k in lv for k in NEEDS_SURVIVAL): skipped += 1; continue
        if any(lv.endswith(k) for k in getattr(S, "UNSUPPORTED", ())): unsupported += 1; continue
        hv = [masked(e, lv) for e in ev]; ho = [masked(e, lv) for e in eo]
        if lv.endswith(": Op4: help gamerule"): hv.sort(); ho.sort()          # one line per rule, in the hash order of the run
        checks += 1; packets += len(ev)
        if hv == ho:
            if verbose: print(f"ok    {p}: {lv}  ({len(ev)} packets)")
            continue
        fails += 1
        print(f"FAIL  {p}: {lv}")
        for i in range(max(len(ev), len(eo))):
            a = ev[i] if i < len(ev) else None; b = eo[i] if i < len(eo) else None
            same = a is not None and b is not None and hv[i] == ho[i]
            print(f"   {'=' if same else '!'} vanilla: {describe(a) if a else '-'}")
            if not same: print(f"     dbcraft: {describe(b) if b else '-'}")
print(f"{checks - fails} of {checks} (player, step) pairs identical ({packets} packets in all on the vanilla side)" + (f"; {skipped} pairs of death steps skipped (they need the survival module, --survival)" if skipped else "")
      + (f"; {unsupported} pairs of steps skipped that use what dbcraft does not support (tests/e2e/cmd_steps.py UNSUPPORTED)" if unsupported else ""))
sys.exit(1 if fails else 0)
