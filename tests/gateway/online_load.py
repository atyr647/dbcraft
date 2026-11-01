#!/usr/bin/env python3
"""Concurrent online-mode logins against a gateway (the reference gateway or the Rust one) with the stub session server: how long does a full encrypted login take
(hello -> encryption request -> key response -> session check -> login_finished) when many clients arrive at once?

usage: online_load.py GATEWAY_PORT STUB_PORT PGPORT N CONCURRENCY [--compression T]
Reports logins/s and the latency distribution (client side, wall clock), then the gateway's own tick statistics from net.gateway_control.
Note: the client is Python with real RSA/AES, so beyond a few hundred concurrent clients the CLIENT is the bottleneck: read the numbers as a floor."""
import argparse, os, statistics, sys, time
from concurrent.futures import ThreadPoolExecutor
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import online_test as ot

def one(i, g, s):
    t = time.perf_counter()
    r = ot.login(g, s, "L%d" % i)
    dt = time.perf_counter() - t
    ok = r["outcome"] == "finished"
    r["client"].close()
    return ok, dt

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("gw_port", type=int); ap.add_argument("stub_port", type=int); ap.add_argument("pg_port", type=int)
    ap.add_argument("n", type=int); ap.add_argument("concurrency", type=int); ap.add_argument("--compression", type=int, default=-1)
    a = ap.parse_args()
    ot.psql(a.pg_port, "update mc.server_property set value = 'true' where key = 'online-mode'; update mc.server_property set value = '%d' where key = 'network-compression-threshold'; "
                       "update mc.server_property set value = 'false' where key = 'white-list'; update mc.server_property set value = '100000' where key = 'max-players'; "
                       "update net.gateway_control set ticks = 0, max_tick_ms = 0, late_ticks = 0; select net.sync_settings()" % a.compression)
    try:
        t0 = time.perf_counter()
        with ThreadPoolExecutor(max_workers=a.concurrency) as ex:
            res = list(ex.map(lambda i: one(i, a.gw_port, a.stub_port), range(a.n)))
        wall = time.perf_counter() - t0
        lat = sorted(d for ok, d in res if ok)
        fails = sum(1 for ok, _ in res if not ok)
        def pct(p): return lat[min(len(lat) - 1, int(p * len(lat)))] * 1000 if lat else float("nan")
        print("logins: %d ok, %d failed, %d concurrent clients, compression %d" % (len(lat), fails, a.concurrency, a.compression))
        print("throughput: %.1f logins/s (%.2f s wall)" % (len(lat) / wall, wall))
        print("latency ms: p50 %.0f  p95 %.0f  p99 %.0f  max %.0f  mean %.0f" % (pct(.5), pct(.95), pct(.99), lat[-1] * 1000 if lat else float("nan"), statistics.mean(lat) * 1000 if lat else float("nan")))
        print("gateway: " + ot.psql(a.pg_port, "select 'ticks=' || ticks, 'max_tick_ms=' || round(max_tick_ms::numeric, 1), 'late_ticks=' || late_ticks, 'connections=' || connections from net.gateway_control").replace("|", " "))
        print("session server queries seen: " + ot.psql(a.pg_port, "select 'n/a (see the stub log)'"))
    finally:
        ot.psql(a.pg_port, "update mc.server_property set value = 'false' where key = 'online-mode'; update mc.server_property set value = '-1' where key = 'network-compression-threshold'; "
                           "update mc.server_property set value = '10' where key = 'max-players'; select net.sync_settings()")
    sys.exit(1 if fails else 0)

if __name__ == "__main__":
    main()
