#!/usr/bin/env python3
"""What OTHER players see: scripted clients ("Act" the actor, "Obs" the observer) run the same steps against the REAL vanilla 26.3 server and against dbcraft;
everything each client receives is recorded byte for byte (mcclient.Client.dump) and tests/e2e/compare_vis.py compares the two.

usage: tests/e2e/vis_probe.py SCENARIO --port P --out PREFIX [--rcon RCONPORT --rcon-pw PW]      (vanilla: the operator is made with RCON `op`)
                                                              [--psql 'psql -X -At -h /tmp -p PORT -U postgres dbcraft']                (dbcraft: the operator is made in SQL)
  SCENARIO  join      Obs is online; Act joins for the first time, is seen, leaves; joins again (a returning player); leaves
            pose      Act sneaks, sprints, swings, changes the client information (skin layers, left hand), is moved to creative mode, holds, wears and carries items,
                      changes the hotbar slot, is switched to spectator and back (what Obs is told at each step)
            walk      Act walks, sprints, turns, jumps, moves 9 blocks in one packet and is teleported while Obs watches (one position packet per tick, locked to the server's ticks)
            latency   Act and Obs idle for 38 s (more than 601 ticks even for a gateway that ticks at 17 Hz): the latency broadcast of the tab list (every 601 ticks)
            range     Act walks away from Obs in steps of chunks and back: when does each see the other (tracking range, view distance)
            view      Act reports a smaller view distance than the server's (client_information), then a larger one, and walks: set_chunk_cache_radius, chunks
Writes PREFIX_<scenario>_act.jsonl and PREFIX_<scenario>_obs.jsonl; marks name the steps.  The server must run in survival, flat, no mobs, spawn 0 -60 0.
"""
import argparse, os, struct, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools", "scoreboard"))
import mcclient as m

ap = argparse.ArgumentParser()
ap.add_argument("scenario")
ap.add_argument("--host", default="127.0.0.1"); ap.add_argument("--port", type=int, default=25841)
ap.add_argument("--out", default="/tmp/dbcraft-e2e-vis/vanilla")
ap.add_argument("--rcon", type=int); ap.add_argument("--rcon-pw", default="dbcraft-e2e")
ap.add_argument("--psql", help="psql command line of the dbcraft database (dbcraft side: the operator and the state reset)")
ap.add_argument("--act", default="Act"); ap.add_argument("--obs", default="Obs")
ap.add_argument("--view", type=int, default=3, help="the server's view distance (range scenario)")
a = ap.parse_args()
os.makedirs(os.path.dirname(a.out), exist_ok=True)
rc = None
if a.rcon:
    import common as C
    rc = C.Rcon(port=a.rcon, pw=a.rcon_pw)


def sql(q):
    return subprocess.run(a.psql.split() + ["-c", q], capture_output=True, text=True, check=True).stdout


def server(cmd):
    """a server-side command (vanilla: RCON; dbcraft: the matching SQL where there is one)"""
    if rc: return rc.cmd(cmd)


def cmd(c, text):
    c.send("minecraft:chat_command", m.string(text))


def uuid_of(name): return m.offline_uuid(name)


def make_op(name):
    if rc: rc.cmd("op " + name)
    else: sql(f"insert into mc.op (uuid, name, level) values ('{uuid_of(name).hex()}', '{name}', 4) on conflict do nothing")


def settle_all(cs, quiet=0.4, timeout=4.0):
    for c in cs: c.settle(quiet, timeout)


def both(cs, label):
    for c in cs: c.mark(label)


def tick(c, n=1):
    for _ in range(n):
        c.send("minecraft:client_tick_end"); time.sleep(0.05)


def stand(c, n=1):
    for _ in range(n):
        c.send("minecraft:client_tick_end"); c.send("minecraft:move_player_status_only", b"\x01"); time.sleep(0.05)


def client_information(view=3, skin=0x7f, hand=1):
    # language, view distance (byte), chat visibility (VarInt 0 = full), chat colors, skin parts (byte), main hand (VarInt: 0 left, 1 right), text filtering, allow listing, particles (VarInt)
    return (m.string("en_us") + bytes([view]) + m.varint(0) + b"\x01" + bytes([skin]) + m.varint(hand) + b"\x00" + b"\x01" + m.varint(0))


def creative_slot(c, slot, item, count=1):
    c.send("minecraft:set_creative_mode_slot", m.i16(slot) + (m.stack(item, count) if item else m.varint(0)))


def joined(c, quiet):
    """a client that has just connected: wait for its first chunk batch (a vanilla server that is slow to start sends nothing for a while), then for quiet"""
    c.wait_for("minecraft:chunk_batch_finished", 30.0); c.settle(quiet, 15.0)


def join_both():
    o = m.Client(a.host, a.port, a.obs); joined(o, 1.0)
    x = m.Client(a.host, a.port, a.act); joined(x, 1.0); o.settle(1.0, 5.0)
    return x, o


def place(x, o, ax=0.5, az=0.5, ox=4.5, oz=0.5):
    """both at known spots (the real server spreads new players around the spawn); then idle ticks so the server's idea of the position is the teleport target"""
    make_op(a.act)
    cmd(x, f"tp {a.act} {ax} -60 {az}"); cmd(x, f"tp {a.obs} {ox} -60 {oz}"); settle_all((x, o), 0.8, 4.0)
    stand(x, 3); stand(o, 3); settle_all((x, o), 0.5, 3.0)


def dump(x, o, scn):
    time.sleep(0.4)
    x.dump(f"{a.out}_{scn}_act.jsonl"); o.dump(f"{a.out}_{scn}_obs.jsonl")
    print("recorded", f"{a.out}_{scn}_act.jsonl", f"{a.out}_{scn}_obs.jsonl")
    x.close(); o.close()


scn = a.scenario
if scn == "join":
    o = m.Client(a.host, a.port, a.obs); joined(o, 1.0)
    o.mark("act joins (first time)")
    x = m.Client(a.host, a.port, a.act, info=client_information(3, 0x7f, 0)); joined(x, 1.5); o.settle(1.5, 6.0)          # Act's client says: view distance 3, all skin layers, LEFT hand
    x.mark("first session over the burst"); o.mark("first session over the burst")
    stand(x, 8); settle_all((x, o), 0.6, 3.0)
    o.mark("act leaves"); x.close(); o.settle(1.0, 5.0)
    o.mark("act joins again (returning)")
    x2 = m.Client(a.host, a.port, a.act, info=client_information(3, 0x7f, 0)); joined(x2, 1.5); o.settle(1.5, 6.0)
    x2.mark("second session over the burst"); o.mark("second session over the burst")
    stand(x2, 8); settle_all((x2, o), 0.6, 3.0)
    o.mark("act leaves for good"); time.sleep(0.2)
    x.dump(f"{a.out}_{scn}_act.jsonl"); x2.dump(f"{a.out}_{scn}_act2.jsonl"); o.dump(f"{a.out}_{scn}_obs.jsonl")
    print("recorded", f"{a.out}_{scn}_*.jsonl")
    x2.close(); o.close()
elif scn == "pose":
    x, o = join_both(); place(x, o); cs = (x, o)
    steps = [
        ("sneak on",  lambda: x.send("minecraft:player_input", b"\x20")),
        ("sneak off", lambda: x.send("minecraft:player_input", b"\x00")),
        ("sneak on and off in one tick", lambda: (x.send("minecraft:player_input", b"\x20"), x.send("minecraft:player_input", b"\x00"))),
        ("sprint on", lambda: x.send("minecraft:player_command", m.varint(0) + m.varint(1) + m.varint(0))),
        ("sprint off", lambda: x.send("minecraft:player_command", m.varint(0) + m.varint(2) + m.varint(0))),
        ("swing", lambda: x.send("minecraft:punch")),
        ("swing again", lambda: x.send("minecraft:punch")),
        ("client information: all skin layers, right hand", lambda: x.send("minecraft:client_information", client_information(3, 0x7f, 1))),
        ("client information: no skin layers, left hand", lambda: x.send("minecraft:client_information", client_information(3, 0x00, 0))),
        ("client information: cape and hat, right hand", lambda: x.send("minecraft:client_information", client_information(3, 0x41, 1))),
        ("client information: the same again", lambda: x.send("minecraft:client_information", client_information(3, 0x41, 1))),
        ("creative", lambda: cmd(x, f"gamemode creative {a.act}")),
        ("main hand: iron sword", lambda: creative_slot(x, 36, "minecraft:iron_sword")),
        ("hotbar slot 1 (empty)", lambda: x.send("minecraft:set_carried_item", m.i16(1))),
        ("hotbar slot 1: diamond", lambda: creative_slot(x, 37, "minecraft:diamond", 3)),
        ("hotbar slot 0 again (the sword)", lambda: x.send("minecraft:set_carried_item", m.i16(0))),
        ("off hand: shield", lambda: creative_slot(x, 45, "minecraft:shield")),
        ("head: iron helmet", lambda: creative_slot(x, 5, "minecraft:iron_helmet")),
        ("chest: diamond chestplate", lambda: creative_slot(x, 6, "minecraft:diamond_chestplate")),
        ("legs and feet in one tick", lambda: (creative_slot(x, 7, "minecraft:golden_leggings"), creative_slot(x, 8, "minecraft:netherite_boots"))),
        ("main hand: empty", lambda: creative_slot(x, 36, None)),
        ("main hand: stone x 5", lambda: creative_slot(x, 36, "minecraft:stone", 5)),
        ("main hand: stone x 6 (count only)", lambda: creative_slot(x, 36, "minecraft:stone", 6)),
        ("sneak on in creative", lambda: x.send("minecraft:player_input", b"\x20")),
        ("sneak off in creative", lambda: x.send("minecraft:player_input", b"\x00")),
        ("spectator", lambda: cmd(x, f"gamemode spectator {a.act}")),
        ("survival", lambda: cmd(x, f"gamemode survival {a.act}")),
        ("adventure", lambda: cmd(x, f"gamemode adventure {a.act}")),
        ("creative again", lambda: cmd(x, f"gamemode creative {a.act}")),
    ]
    for label, fn in steps:
        both(cs, label); fn(); settle_all(cs, 0.35, 2.5); stand(x, 1); stand(o, 1)
    both(cs, "end")
    dump(x, o, scn)
elif scn == "walk":
    # Movement as the observer sees it.  Act sends one position packet per tick like a real client, locked to the server's tick: the sends of every block of
    # <= 19 ticks start at the arrival of a set_time packet (every 20 ticks) plus half a tick, so each packet lands in its own tick on both servers.
    x, o = join_both(); place(x, o, 0.5, 0.5, 4.5, 12.5); cs = (x, o)
    st = {"x": 0.5, "y": -60.0, "z": 0.5, "yaw": 0.0, "pitch": 0.0}
    def sync():
        k = x.count(); e = x.wait_for("minecraft:set_time", 3.0, after=k)
        return e["t"] if e else time.time() - x.t0
    def ticks(n, fn):
        done = 0
        while done < n:
            t0 = sync(); m_ = min(19, n - done)
            for i in range(m_):
                wait = t0 + (i + 1) * 0.05 + 0.025 - (time.time() - x.t0)
                if wait > 0: time.sleep(wait)
                x.send("minecraft:client_tick_end"); fn(done + i); stand(o, 0)
            done += m_
    def pos(og=1):
        x.send("minecraft:move_player_pos", struct.pack(">ddd", st["x"], st["y"], st["z"]) + bytes([og]))
    def posrot(og=1):
        x.send("minecraft:move_player_pos_rot", struct.pack(">dddff", st["x"], st["y"], st["z"], st["yaw"], st["pitch"]) + bytes([og]))
    def rot(og=1):
        x.send("minecraft:move_player_rot", struct.pack(">ff", st["yaw"], st["pitch"]) + bytes([og]))
    def step_walk(dx):
        def f(i): st["x"] += dx; pos()
        return f
    def step_turn(i): st["yaw"] += 9.0; rot()
    def step_walkturn(i): st["x"] += 0.2158; st["yaw"] -= 4.5; st["pitch"] = max(-60.0, st["pitch"] - 1.0); posrot()
    jump_vy = [0.42, 0.3332, 0.2481, 0.1647, 0.0831, 0.0023, -0.0784, -0.1553, -0.2305, -0.3043, -0.3764, -0.4472, -0.5164, -0.5841]
    def step_jump(i):
        if i >= len(jump_vy): return
        st["y"] = max(-60.0, st["y"] + jump_vy[i]); st["x"] += 0.2158; posrot(1 if st["y"] <= -60.0 else 0)
    both(cs, "start"); ticks(20, lambda i: None)
    both(cs, "walk east 40 ticks"); ticks(40, step_walk(0.2158))
    both(cs, "stand 30 ticks"); ticks(30, lambda i: None)
    both(cs, "sprint east 30 ticks"); x.send("minecraft:player_command", m.varint(0) + m.varint(1) + m.varint(0)); ticks(30, step_walk(0.2806))
    x.send("minecraft:player_command", m.varint(0) + m.varint(2) + m.varint(0)); ticks(5, lambda i: None)
    both(cs, "turn in place 20 ticks"); ticks(20, step_turn)
    both(cs, "walk and turn 20 ticks"); ticks(20, step_walkturn)
    both(cs, "jump"); ticks(16, step_jump)
    both(cs, "stand again"); ticks(10, lambda i: None)
    both(cs, "move 9 blocks in one packet"); st["x"] += 9.0; ticks(1, lambda i: pos()); ticks(6, lambda i: None)
    both(cs, "move 7 blocks in one packet"); st["x"] -= 7.0; ticks(1, lambda i: pos()); ticks(6, lambda i: None)
    both(cs, "teleport 10 blocks with /tp"); st["x"] += 10.0; cmd(x, f"tp {a.act} {st['x']} -60 0.5"); settle_all(cs, 0.3, 2.0); ticks(8, lambda i: None)
    both(cs, "teleport 40 blocks with /tp"); st["x"] += 40.0; cmd(x, f"tp {a.act} {st['x']} -60 0.5"); settle_all(cs, 0.3, 2.0); ticks(8, lambda i: None)
    both(cs, "teleport next to Obs with /tp"); st["x"] = 3.5; cmd(x, f"tp {a.act} 3.5 -60 2.5"); settle_all(cs, 0.3, 2.0); ticks(8, lambda i: None)
    both(cs, "end")
    dump(x, o, scn)
elif scn == "latency":
    x, o = join_both(); place(x, o); both((x, o), "idle")
    t_end = time.time() + 38.0
    while time.time() < t_end:
        stand(x); stand(o)
    both((x, o), "end")
    dump(x, o, scn)
elif scn == "range":
    x, o = join_both(); place(x, o); cs = (x, o)
    both(cs, "start")
    # walk Act away in steps of 2 chunks (teleport + a position packet), then back
    for dist in (16, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 200, 256):
        both(cs, f"act at x={dist}")
        cmd(x, f"tp {a.act} {dist + 0.5} -60 0.5"); settle_all(cs, 0.3, 2.0); stand(x, 3); stand(o, 3); settle_all(cs, 0.5, 2.5)
    for dist in (200, 160, 128, 96, 64, 48, 32, 16, 0):
        both(cs, f"act back at x={dist}")
        cmd(x, f"tp {a.act} {dist + 0.5} -60 0.5"); settle_all(cs, 0.3, 2.0); stand(x, 3); stand(o, 3); settle_all(cs, 0.5, 2.5)
    both(cs, "end")
    dump(x, o, scn)
elif scn == "view":
    x, o = join_both(); place(x, o); cs = (x, o)
    both(cs, "start")
    for vd in (2, 5, 8, 12, 3):
        both(cs, f"client view distance {vd}")
        x.send("minecraft:client_information", client_information(vd)); settle_all(cs, 0.8, 4.0); stand(x, 2)
    both(cs, "walk with view distance 2")
    x.send("minecraft:client_information", client_information(2)); settle_all(cs, 0.8, 4.0)
    for dx in range(1, 5):
        cmd(x, f"tp {a.act} {dx * 16 + 0.5} -60 0.5"); settle_all(cs, 0.5, 3.0); stand(x, 3); settle_all(cs, 0.6, 3.0)
    both(cs, "end")
    dump(x, o, scn)
else:
    sys.exit("unknown scenario " + scn)
