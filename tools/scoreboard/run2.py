"""Scoreboard scenarios 6-9: block edit throughput, chunk loading, world size on disk, save stall and crash recovery.  Used by run.py (same interleaving,
same result file).  Scenario 5 (entities) is measured by tools/entity/ and docs/ENTITY.md; scenario 10 (tail latency) is `run.py pop --hold 600`.
"""
import json, math, os, re, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C
from run import Vanilla, Dbcraft, sh, dbq, LoadGens, merge_done, client_summary, chunks_expected, tree_pss, pss_mib, TOOLS

DIM = "minecraft:overworld"


def psql_timed(stmts, timeout=3600):
    """Run statements in ONE psql session with \\timing on; returns the server-side time of each statement in ms."""
    script = "\\timing on\n" + ";\n".join(stmts) + ";\n"
    r = subprocess.run(["psql", "-X", "-q", "-At", "-h", "/tmp", "-p", str(C.PGPORT), "-U", "postgres", "dbcraft"], input=script, capture_output=True,
                       text=True, timeout=timeout)
    return [float(m) for m in re.findall(r"^Time: ([\d.]+) ms", r.stdout, re.M)]


def lat_stats(ms):
    s = C.stats(ms)
    return {"n": s["n"], "p50_ms": s["p50"], "p95_ms": s["p95"], "max_ms": s["max"], "mean_ms": s["mean"]}


def scenario_blocks(srv, a):
    srv.start(6, 0)
    out = {}
    if srv.name == "vanilla":
        rc = srv.rcon
        rc.cmd("forceload add -64 -64 63 63")
        time.sleep(5)

        def cmd_times(cmds, ok_words):
            ts, bad, first = [], 0, None
            for c in cmds:
                t = time.perf_counter()
                resp = rc.cmd(c)
                dt = (time.perf_counter() - t) * 1000.0
                if first is None:
                    first = resp
                if any(w in resp for w in ok_words):
                    ts.append(dt)
                else:
                    bad += 1
            return ts, bad, first
        out["gamerule_response"] = rc.cmd("gamerule max_block_modifications 2000000")
        single, bad_s, first_s = cmd_times(["setblock %d -60 %d minecraft:%s" % (x % 90 - 45, z % 90 - 45, "stone" if (x + z) % 2 else "gold_block") for x, z in
                                            ((i * 7, i * 13) for i in range(300))], ("Changed the block",))
        f1, bad_1, first_1 = cmd_times(["fill 0 -60 0 9 -51 9 minecraft:%s" % b for _ in range(8) for b in ("stone", "air")], ("Successfully filled",))
        f100, bad_100, first_100 = cmd_times(["fill -25 -60 -25 24 -21 24 minecraft:%s" % b for _ in range(3) for b in ("stone", "air")], ("Successfully filled",))
        out["responses"] = {"setblock": first_s, "fill1k": first_1, "fill100k": first_100}
        out["failed_commands"] = {"setblock": bad_s, "fill1k": bad_1, "fill100k": bad_100}
        out["blocks_per_fill_1k"], out["blocks_per_fill_100k"] = 1000, 100000
    else:
        dbq("select mc.pregenerate('%s', 0, 0, 4, true)" % DIM)
        stmts = ["select mc.set_block('%s', %d, -60, %d, 'minecraft:%s')" % (DIM, x % 90 - 45, z % 90 - 45, "stone" if (x + z) % 2 else "gold_block")
                 for x, z in ((i * 7, i * 13) for i in range(2000))]
        single = psql_timed(stmts)
        f1 = psql_timed(["select mc.fill('%s', 0, -60, 0, 9, -51, 9, 'minecraft:%s')" % (DIM, b) for _ in range(8) for b in ("stone", "air")])
        f100 = psql_timed(["select mc.fill('%s', -25, -60, -25, 24, -21, 24, 'minecraft:%s')" % (DIM, b) for _ in range(3) for b in ("stone", "air")])
        # a batch of scattered edits in ONE call (what a game script would do): 1,000 positions
        xs = ",".join(str((i * 37) % 90 - 45) for i in range(1000))
        zs = ",".join(str((i * 53) % 90 - 45) for i in range(1000))
        sb = psql_timed(["select mc.set_blocks('%s', array[%s], array_fill(-60, array[1000]), array[%s], array_fill('minecraft:diamond_block'::text, array[1000]))" % (DIM, xs, zs),
                         "select mc.set_blocks('%s', array[%s], array_fill(-60, array[1000]), array[%s], array_fill('minecraft:air'::text, array[1000]))" % (DIM, xs, zs)])
        out["set_blocks_1000_scattered_ms"] = sb
    out["single_edit"] = lat_stats(single)
    out["single_edits_per_s"] = 1000.0 / max(1e-9, out["single_edit"]["mean_ms"])
    out["fill_1k"] = lat_stats(f1)
    out["fill_100k"] = lat_stats(f100)
    out["fill_100k_blocks_per_s"] = 100000.0 / (out["fill_100k"]["p50_ms"] / 1000.0)
    return out


def scenario_chunkload(srv, a):
    """Time for ONE joiner to receive every chunk of its view: into an unexplored world, then (after it left) into the explored one."""
    srv.start(a.vd, 2, ["Bot0", "Bot1"], 0)
    time.sleep(3)
    out = {}
    for label, idx in (("unexplored", 0), ("explored", 1)):
        lg = LoadGens(srv.port, 1, 0.0, a.vd, 0.0, 300, 2, procs=1, probe=False, first0=idx)
        try:
            ready = lg.wait_event("READY", 360)
            if not ready:
                out[label] = {"error": "not ready"}
            else:
                lg.go()
                done = lg.wait_event("DONE", 60)
                m = merge_done(done)
                out[label] = {"chunks": m["chunks_per_client"], "to_play_s": m["join_to_play_s"], "to_last_chunk_s": m["join_to_last_chunk_s"], "mib": m["rx_bytes"] / 1048576.0}
        finally:
            lg.close()
        time.sleep(2)
    return out


def scenario_world10k(srv, a):
    """10,000 flat chunks: generation time, size on disk after a save, the save stall, then kill -9 and recovery."""
    srv.start(2, 0)
    out = {}
    t0 = time.time()
    if srv.name == "vanilla":
        rc = srv.rcon
        for cx in range(0, 100, 16):
            for cz in range(0, 100, 16):
                w, h = min(16, 100 - cx), min(16, 100 - cz)
                rc.cmd("forceload add %d %d %d %d" % ((cx - 50) * 16, (cz - 50) * 16, (cx - 50 + w) * 16 - 1, (cz - 50 + h) * 16 - 1))
        time.sleep(5)
        out["generate_s"] = time.time() - t0
        t = time.perf_counter()
        rc.cmd("save-all flush")
        out["save_all_flush_s"] = time.perf_counter() - t               # worst case: 10,000 loaded chunks, all dirty
        rc.cmd("forceload remove all")                                  # the forced-load tickets persist and would be reloaded at every start
        time.sleep(8)
        rc.cmd("save-all flush")
        out["world_bytes"] = int(sh("du", "-sb", os.path.join(C.VANILLA_DIR, "world")).split()[0])
        rc.cmd("forceload add 0 0 15 15")                               # ONE chunk stays loaded for the edit test
        time.sleep(2)
        rc.cmd("setblock 5 -60 5 minecraft:diamond_block")
        rc.cmd("save-all flush")
        # crash: another edit that was never saved, then kill -9
        rc.cmd("setblock 6 -60 5 minecraft:gold_block")
        time.sleep(1.0)
        pid = C.vanilla_pid()
        t_kill = time.time()
        sh(os.path.join(TOOLS, "vanilla.sh"), "kill9")
        sh(os.path.join(TOOLS, "vanilla.sh"), "start", "2")
        out["recovery_to_accepting_s"] = time.time() - t_kill
        rc2 = C.Rcon()
        time.sleep(2)
        out["saved_edit_survived"] = "diamond_block" in rc2.cmd("execute if block 5 -60 5 minecraft:diamond_block")
        out["unsaved_edit_survived"] = "Test passed" in rc2.cmd("execute if block 6 -60 5 minecraft:gold_block")
        out["saved_edit_survived"] = "Test passed" in rc2.cmd("execute if block 5 -60 5 minecraft:diamond_block")
    else:
        size0 = int(dbq("select pg_database_size('dbcraft')"))
        dbq("select mc.generate_batch('%s', array_agg(x), array_agg(z)) from generate_series(-50, 49) x, generate_series(-50, 49) z" % DIM, timeout=1800)
        out["generate_s"] = time.time() - t0
        out["chunks"] = int(dbq("select count(*) from mc.chunk where dimension = '%s'" % DIM))
        dbq("select mc.set_block('%s', 5, -60, 5, 'minecraft:diamond_block')" % DIM)
        t = time.perf_counter()
        dbq("checkpoint")
        out["checkpoint_s"] = time.perf_counter() - t
        out["db_bytes_growth"] = int(dbq("select pg_database_size('dbcraft')")) - size0
        out["world_bytes"] = int(dbq("select sum(pg_total_relation_size(c.oid)) from pg_class c join pg_namespace n on n.oid = c.relnamespace "
                                     "where n.nspname = 'mc' and c.relkind in ('r', 'm') and c.relname in ('chunk', 'chunk_section', 'chunk_light', 'chunk_cache', 'block_entity')") or 0)
        dbq("select mc.set_block('%s', 6, -60, 5, 'minecraft:gold_block')" % DIM)
        time.sleep(1.0)
        before = int(dbq("select count(*) from mc.chunk where dimension = '%s'" % DIM))
        t_kill = time.time()
        sh(os.path.join(TOOLS, "dbcraft.sh"), "kill9")
        sh(os.path.join(TOOLS, "dbcraft.sh"), "start")
        out["recovery_to_accepting_s"] = time.time() - t_kill
        out["chunks_intact"] = int(dbq("select count(*) from mc.chunk where dimension = '%s'" % DIM)) == before
        out["saved_edit_survived"] = dbq("select mc.get_block('%s', 5, -60, 5)" % DIM) == "minecraft:diamond_block"
        out["unsaved_edit_survived"] = dbq("select mc.get_block('%s', 6, -60, 5)" % DIM) == "minecraft:gold_block"
    return out


def _server_thread(pid):
    import glob
    for t in glob.glob("/proc/%d/task/*" % pid):
        try:
            if open(t + "/comm").read().strip() == "Server thread":
                return t
        except OSError:
            pass
    return None


def _sched_ns(path):
    try:
        return int(open(path).read().split()[0])
    except OSError:
        return 0


class PsqlSession:
    """One long-lived psql session with \\timing on, like an admin's or a game script's connection (a fresh backend per statement would measure its cold plan caches, 20 ms for the first set_block)."""
    def __init__(self):
        self.p = subprocess.Popen(["psql", "-X", "-q", "-At", "-h", "/tmp", "-p", str(C.PGPORT), "-U", "postgres", "dbcraft"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT, text=True, bufsize=1)
        self.p.stdin.write("\\timing on\n")

    def run(self, stmt):
        self.p.stdin.write(stmt + ";\n\\echo @@DONE@@\n")
        self.p.stdin.flush()
        ms = None
        for line in self.p.stdout:
            if line.startswith("@@DONE@@"):
                break
            m = re.match(r"Time: ([\d.]+) ms", line)
            if m:
                ms = float(m.group(1))
        return ms

    def close(self):
        try:
            self.p.stdin.close()
            self.p.wait(timeout=10)
        except Exception:
            self.p.kill()


def scenario_edit(srv, a):
    """Edits with nobody in range (--n 0) or with ONE real client connected (--n 1): the statement (vanilla: RCON round trip; dbcraft: server-side time of the SQL call) and the tick
    cost of the edit.  Each sample: wait 0.4 s, run the statement, wait 0.6 s.  Tick cost: vanilla = CPU of the Server thread over the 0.6 s after the command start minus the same
    thread's idle CPU over a window of equal length; dbcraft = sum of ms_total of the ticks the gateway logged in that window minus the idle ticks' mean (the broadcast of the change
    goes out in the tick that follows the statement).  The viewer is the scripted client of tests/e2e/mcclient.py at the spawn.  Same statements as scenario_blocks."""
    sys.path.insert(0, os.path.join(C.REPO, "tests", "e2e"))
    import mcclient as m
    srv.start(10, 0)
    viewer = a.n > 0
    cl = None
    out = {"viewer": viewer}
    if srv.name == "vanilla":
        rc = srv.rcon
        rc.cmd("gamerule max_block_modifications 2000000")
        rc.cmd("gamerule random_tick_speed 0")
        rc.cmd("forceload add -64 -64 79 79")
        if viewer:
            cl = m.Client("127.0.0.1", srv.port, "Prober")
            cl.settle(1.0, 15.0)
        time.sleep(3)
        st = _server_thread(srv.pid)
        cpu = lambda: _sched_ns(st + "/schedstat") / 1e6
        pids = []
    else:
        dbq("select mc.pregenerate('%s', 0, 0, 6, true)" % DIM)
        sess = PsqlSession()
        for i in range(60):                           # warm this session's plans like a running admin connection would have (not measured)
            sess.run("select mc.set_block('%s', %d, -60, %d, 'minecraft:stone')" % (DIM, i % 30, i % 17))
        for b in ("stone", "air", "stone", "air"):
            sess.run("select mc.fill('%s', 0, -60, 0, 9, -51, 9, 'minecraft:%s')" % (DIM, b))
        if viewer:
            cl = m.Client("127.0.0.1", srv.port, "Prober")
            cl.settle(1.0, 15.0)
        time.sleep(3)

    def idle_tick_ms():
        r = dbq("select coalesce(avg(ms_total), 0) from (select ms_total from mc.server_tick_log order by tick desc limit 40) q")
        return float(r)

    def sample(cmd_v, stmt_d, reps):
        """returns (statement ms list, tick cost ms list)"""
        st_ms, tk_ms = [], []
        if srv.name == "vanilla":
            time.sleep(0.4)
            i0 = cpu(); time.sleep(0.6); idle = cpu() - i0
            for r in range(reps + 1):
                time.sleep(0.4)
                c0 = cpu(); t0 = time.perf_counter()
                resp = srv.rcon.cmd(cmd_v(r))
                dt = (time.perf_counter() - t0) * 1000.0
                time.sleep(0.6)
                c1 = cpu()
                if r == 0:
                    continue                      # warm-up
                st_ms.append(dt); tk_ms.append(max(0.0, c1 - c0 - idle))
        else:
            base = idle_tick_ms()
            for r in range(reps + 1):
                time.sleep(0.4)
                t_a = int(dbq("select coalesce(max(tick), 0) from mc.server_tick_log"))
                ms = [sess.run(stmt_d(r))]
                time.sleep(0.6)
                rows = dbq("select ms_total from mc.server_tick_log where tick > %d order by tick" % t_a).split()
                if r == 0:
                    continue
                st_ms.append(ms[0])
                xs = [float(x) for x in rows if x]
                tk_ms.append(max(0.0, sum(xs) - base * len(xs)))
                out.setdefault("worst_tick_ms", []).append(max(xs) if xs else 0.0)
        return st_ms, tk_ms

    def blk(r, names=("stone", "gold_block")):
        return names[r % 2]
    # single block edits at varying positions, alternating blocks
    def one(r):
        x, z = (r * 7) % 90 - 45, (r * 13) % 90 - 45
        return x, z
    nsingle = a.edit_single
    out["single"], out["single_tick"] = sample(lambda r: "setblock %d -60 %d minecraft:%s" % (*one(r), blk(r)),
                                              lambda r: "select mc.set_block('%s', %d, -60, %d, 'minecraft:%s')" % (DIM, *one(r), blk(r)), nsingle)
    out["fill1k"], out["fill1k_tick"] = sample(lambda r: "fill 0 -60 0 9 -51 9 minecraft:%s" % blk(r, ("stone", "air")),
                                              lambda r: "select mc.fill('%s', 0, -60, 0, 9, -51, 9, 'minecraft:%s')" % (DIM, blk(r, ("stone", "air"))), a.edit_fill)
    out["fill100k"], out["fill100k_tick"] = sample(lambda r: "fill -25 -60 -25 24 -21 24 minecraft:%s" % blk(r, ("stone", "air")),
                                                  lambda r: "select mc.fill('%s', -25, -60, -25, 24, -21, 24, 'minecraft:%s')" % (DIM, blk(r, ("stone", "air"))), a.edit_fill)
    for k in ("single", "fill1k", "fill100k"):
        out[k + "_stats"] = lat_stats(out[k])
        out[k + "_tick_stats"] = lat_stats(out[k + "_tick"])
    if srv.name != "vanilla":
        sess.close()
    if cl:
        cl.close()
        time.sleep(1)
    return out


SCENARIOS = {"edit": scenario_edit, "blocks": scenario_blocks, "chunkload": scenario_chunkload, "world10k": scenario_world10k}
