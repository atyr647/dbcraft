#!/usr/bin/env python3
"""Reference model of ItemEntity physics in 26.3 (read from the bytecode of ItemEntity.tick / Entity.move), checked against vanilla's recorded per-tick states.

usage: tools/entity/model.py NAME ID_MOD4        e.g. rest 3      (reads tests/fixtures/captured/entity_traj_NAME.json)
The SQL implementation (sql/510_entity_physics.sql) is a set-based port of exactly this; tests/sql/510_entity_physics.sql compares it with the same recordings.
Rules (per tick, state after the tick is what vanilla reports):
  tickCount += 1
  vy -= 0.04                                              (applyGravity, double)
  if onGround and (vx^2+vz^2) <= 9.999999747378752e-06 and (tickCount + id) % 4 != 0:   sleep: no move, no drag
  else: move(v); f = 0.98F (float); if onGround(after move): f = 0.6F * 0.98F (float product; 0.6 = block friction); v = (vx*f, vy*0.98F, vz*f); if onGround and vy < 0: vy *= -0.5
move: axis order Y first, then X then Z (if |vx| >= |vz|) else Z then X; each axis is clipped by solid full-cube cells; a clipped axis zeroes that velocity component;
  onGround = (vertical movement was clipped and moving down).
"""
import json, math, struct, sys


def f32(x):
    return struct.unpack("f", struct.pack("f", x))[0]


F98 = f32(0.98)
FGROUND = f32(f32(0.6) * F98)
W = 0.25
H = 0.25
EPS = 1e-7


def solid_floor(cx, cy, cz):
    return cy <= -61


def solid_default(cx, cy, cz):
    """the 'wall' recording: flat floor + a stone wall at x=6 (y -60..-58, z -2..8) + a row at z=12"""
    if cy <= -61:
        return True
    if cx == 6 and -60 <= cy <= -58 and -2 <= cz <= 8:      # the recorded wall
        return True
    if -60 == cy and 3 <= cx <= 9 and cz == 12:
        return True
    return False


def collide_axis(pos, d, axis, solid):
    """move the box along one axis by d, clipped by solid unit cells; returns the allowed movement"""
    if abs(d) < EPS:
        return 0.0
    hw = W / 2
    lo = [pos[0] - hw, pos[1], pos[2] - hw]
    hi = [pos[0] + hw, pos[1] + H, pos[2] + hw]
    rng = []
    for a in range(3):
        a0, a1 = lo[a], hi[a]
        if a == axis:
            a0, a1 = (a0 + d, a1) if d < 0 else (a0, a1 + d)
        rng.append((math.floor(a0 + EPS), math.floor(a1 - EPS)))
    best = d
    for cx in range(rng[0][0], rng[0][1] + 1):
        for cy in range(rng[1][0], rng[1][1] + 1):
            for cz in range(rng[2][0], rng[2][1] + 1):
                if not solid(cx, cy, cz):
                    continue
                c = (cx, cy, cz)[axis]
                if d < 0:
                    best = max(best, (c + 1) - lo[axis])
                else:
                    best = min(best, c - hi[axis])
    return best


def step(st, solid=solid_default, idm=0):
    x, y, z, vx, vy, vz, og, t = st
    t += 1
    vy -= 0.04
    if og and (vx * vx + vz * vz) <= 9.999999747378752e-06 and (t + idm) % 4 != 0:
        return (x, y, z, vx, vy, vz, og, t)
    pos = [x, y, z]
    mv = [vx, vy, vz]
    order = [1, 0, 2] if abs(vx) >= abs(vz) else [1, 2, 0]
    got = [0.0, 0.0, 0.0]
    tent = list(pos)
    for a in order:
        d = collide_axis(tent, mv[a], a, solid)
        got[a] = d
        tent[a] += d
    # Entity.move only applies the collided movement when its squared length is above 1.0E-7 (the velocity, drag and collision flags are updated either way)
    if got[0] * got[0] + got[1] * got[1] + got[2] * got[2] > 1.0e-7:
        pos = tent
    vcoll = got[1] != mv[1]
    og = vcoll and mv[1] < 0
    if got[0] != mv[0]:
        vx = 0.0
    if got[2] != mv[2]:
        vz = 0.0
    if vcoll:
        vy = 0.0
    fr = FGROUND if og else F98
    vx, vy, vz = vx * fr, vy * F98, vz * fr
    if og and vy < 0:
        vy *= -0.5
    return (pos[0], pos[1], pos[2], vx, vy, vz, og, t)


def run(name, idm):
    rec = json.load(open(f"tests/fixtures/captured/entity_traj_{name}.json"))["rows"]
    r0 = rec[0]
    st = (*r0["pos"], *r0["motion"], r0["on_ground"], 0)
    solid = solid_default if name == "wall" else solid_floor
    worst = 0.0
    worst_at = None
    for row in rec[1:]:
        st = step(st, solid=solid, idm=idm)
        dev = max(abs(a - b) for a, b in zip(st[:6], (*row["pos"], *row["motion"])))
        if st[6] != row["on_ground"]:
            dev = max(dev, 1.0)
        if dev > worst:
            worst, worst_at = dev, row["tick"]
    return worst, worst_at


if __name__ == "__main__":
    for nm in (sys.argv[1:2] or ["fall", "rest", "slide", "wall"]):
        idm = int(sys.argv[2]) if len(sys.argv) > 2 else 3
        print(nm, "max deviation %.3e at tick %s" % run(nm, idm))
