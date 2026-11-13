#!/usr/bin/env python3
"""The weather clock as a client sees it: /weather with durations, and what the server sends while the rain and thunder levels move (ServerLevel.advanceWeatherCycle: game_event 1
start raining, 2 stop raining, 7 rain level, 8 thunder level; the levels move 0.01 per tick).  One scripted operator "Surv"; per step every game_event the client receives until
it has been quiet for 1.5 s is recorded in order (value as float32), so the SEQUENCE is the clock: its length is the number of ticks the weather took.

usage: tests/e2e/weather_probe.py record --port P --out FILE        (vanilla: OPS=Surv,Obs tests/e2e/vanilla_start.sh;  dbcraft: a dev gateway with Surv as operator)
       tests/e2e/weather_probe.py compare VANILLA.json OURS.json
"""
import json, os, struct, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mcclient as m

STEPS = ["weather clear", "weather rain 40", "weather clear 40", "weather thunder 60", "weather rain 20", "weather thunder 20", "weather clear 30", "weather rain 1", "weather thunder 1",
         "weather clear 1", "weather rain 120", "weather clear"]

def record(port, out, host="127.0.0.1"):
    s = m.Client(host, port, "Surv"); s.settle(1.0, 20.0)
    s.send("minecraft:client_command", m.varint(0)); s.settle(0.4, 2.0)
    def cmd(t): s.send("minecraft:chat_command", m.string(t))
    cmd("gamerule advance_weather true"); cmd("weather clear"); time.sleep(8.0); s.settle(1.0, 10.0)
    res = []
    for c in STEPS:
        k = len(s.events); t0 = time.time(); cmd(c); last = time.time()
        while time.time() - last < 4.5 and time.time() - t0 < 60:
            n = len(s.events); s.send("minecraft:client_tick_end"); time.sleep(0.05)
            if any(e["name"] == "minecraft:game_event" for e in s.events[n:]): last = time.time()
        ev = []
        for e in s.events[k:]:
            if e["dir"] == "clientbound" and e["name"] == "minecraft:game_event":
                b = e["body"]; ev.append([b[0], round(struct.unpack(">f", b[1:5])[0], 7)])
        res.append({"cmd": c, "events": ev})
        print("%-22s %d events" % (c, len(ev)), flush=True)
    json.dump(res, open(out, "w"), indent=0); s.close()

def compare(a, b):
    va, vb = json.load(open(a)), json.load(open(b)); bad = 0
    for x, y in zip(va, vb):
        if x["events"] == y["events"]: print("  same      %-22s %d events" % (x["cmd"], len(x["events"]))); continue
        bad += 1
        print("  DIFFERENT %-22s vanilla %d events, dbcraft %d" % (x["cmd"], len(x["events"]), len(y["events"])))
        for i in range(max(len(x["events"]), len(y["events"]))):
            p = x["events"][i] if i < len(x["events"]) else None; q = y["events"][i] if i < len(y["events"]) else None
            if p != q: print("      %d vanilla %s dbcraft %s" % (i, p, q)); break
    print("%d of %d steps identical" % (len(va) - bad, len(va)))
    return bad

if __name__ == "__main__":
    if sys.argv[1] == "record": record(int(sys.argv[sys.argv.index("--port") + 1]), sys.argv[sys.argv.index("--out") + 1])
    else: sys.exit(1 if compare(sys.argv[2], sys.argv[3]) else 0)
