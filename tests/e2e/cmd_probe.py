#!/usr/bin/env python3
"""Run a scripted list of commands as several players and record everything each client receives.  Run it against the real vanilla 26.3 server and against
dbcraft, then compare with tests/e2e/compare_commands.py.

usage: tests/e2e/cmd_probe.py [--host 127.0.0.1] [--port 25677] [--out /tmp/dbcraft-e2e/vanilla_cmd] [--steps cmd_steps.py] [--wait 0.6]
Joins the players named in STEPS_PLAYERS (offline UUIDs are the same on both servers), waits until each has settled, then performs STEPS: tuples
("Player", "command text") or ("Player", "!chat", "text") or ("Player", "!wait", seconds).  Before each step every client gets a mark "step N: text".
Writes <out>_<Player>.jsonl.  Recordings contain Mojang data and are never committed.
"""
import argparse, importlib.util, os, struct, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mcclient as m

ap = argparse.ArgumentParser()
ap.add_argument("--host", default="127.0.0.1"); ap.add_argument("--port", type=int, default=25677)
ap.add_argument("--out", default="/tmp/dbcraft-e2e/vanilla_cmd")
ap.add_argument("--steps", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "cmd_steps.py"))
ap.add_argument("--wait", type=float, default=0.6, help="seconds to wait after each command")
ap.add_argument("--only", default=None, help="run only steps whose text contains this")
a = ap.parse_args()
spec = importlib.util.spec_from_file_location("cmd_steps", a.steps); S = importlib.util.module_from_spec(spec); spec.loader.exec_module(S)
os.makedirs(os.path.dirname(a.out), exist_ok=True)

def chat(text):
    return m.string(text) + struct.pack(">q", int(time.time() * 1000)) + struct.pack(">q", 0) + b"\x00" + m.varint(0) + b"\x00\x00\x00" + b"\x00"

def settle_all(quiet, timeout):
    """wait until no client has received anything for `quiet` seconds, at most `timeout` seconds in all (a vanilla server never goes quiet: it ticks entities)"""
    end = time.time() + timeout; last = [c.count() for c in clients.values()]; t = time.time()
    while time.time() < end:
        time.sleep(0.05); now = [c.count() for c in clients.values()]
        if now != last: last, t = now, time.time()
        elif time.time() - t >= quiet: return

clients = {}
for name in S.PLAYERS:
    clients[name] = m.Client(a.host, a.port, name)
    for c in clients.values(): c.settle(0.8, 10.0)
for c in clients.values(): c.settle(1.0, 10.0)
n = 0
for step in S.STEPS:
    who, cmd = step[0], step[1]
    if a.only and a.only not in str(step): continue
    n += 1
    label = f"step {n}: {who}: {cmd}" + (f" {step[2]}" if len(step) > 2 else "")
    for c in clients.values(): c.mark(label)
    if cmd == "!wait": time.sleep(step[2]); continue
    if cmd == "!chat": clients[who].send("minecraft:chat", chat(step[2]))
    elif cmd == "!join":
        clients[who] = m.Client(a.host, a.port, who)
        for c in clients.values(): c.mark(label)
    elif cmd == "!leave":
        clients[who].close(); time.sleep(0.5)
    elif cmd == "!send": clients[who].send(step[2], step[3])
    else: clients[who].send("minecraft:chat_command", m.string(cmd))
    time.sleep(a.wait)
    settle_all(0.25, 1.0)
for name, c in clients.items():
    c.dump(f"{a.out}_{name}.jsonl")
    c.close()
print(f"recorded {n} steps for {', '.join(clients)} into {a.out}_*.jsonl")
