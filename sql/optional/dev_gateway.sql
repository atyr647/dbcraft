-- Development gateway, as database code: a stored procedure (untrusted PL/Python) that runs the socket loop INSIDE a Postgres backend and feeds the real tables.
-- Not applied by default; `tools/migrate.sh --dev-gateway` applies it.  It needs `create extension plpython3u` (superuser) and, to hold more than ~1,000
-- connections, a backend open-file limit above the default 1024 (tools/pg-dev.sh raises it; use LimitNOFILE in a service file).
--
--   call net.run(25565);                      -- listens on port 25565 and ticks 20 times a second until stopped
--   update net.gateway_control set stop = true;      -- stops it after the current tick (or select pg_terminate_backend(pid))
--
-- What it does, per 50 ms tick (drift-free: the next tick is scheduled from the start time, not from the end of the previous one):
--   accept new sockets                       -> select net.on_connect(conn_id, ip)
--   read bytes, split frames (VarInt length)  -> one INSERT into net.inbox for the whole tick; inbound compressed frames are inflated here (zlib)
--   sockets that closed                      -> select net.on_disconnect(conn_id)
--   select mc.server_tick()                   the whole game, in SQL
--   select * from net.drain_outbox()          -> append to each connection's write buffer; flush when writable; close when asked
--   commit
--
-- Since sql/800/801 (docs/PERF-IDLE.md) two things differ from the list above:
--   * a tick with nothing for the database (no new socket, no inbound frame, no closed socket) runs only `select mc.server_tick()` and one probe (net.gateway_pending); the outbox is
--     drained when the probe says it holds bytes, and the control row is written every 10th such tick (the stop flag is looked at then);
--   * serverbound chat frames are handled between ticks (net.urgent_chat, then a drain) when the next tick is far enough away: the Rust gateway's urgent lane, same rules.
--   * client_tick_end frames of connections in play that sent fewer than two position packets in the tick are not given to the database (the Rust gateway's skip_tick_end; the play state
--     of a connection comes from net.gateway_ctl, read when net.gateway_pending says there are control rows).  Before docs/PERF-IDLE2.md this gateway queued 200 of them a tick at 200 idle
--     players: 6.8 ms of its tick.
--   * the kinds that may stand ahead of a chat without making it wait come from net.urgent_neutral_play_ids() (sql/971), like the Rust gateway's.
--
-- What it deliberately does NOT do: no encryption and no Mojang session check (online mode is the production gateway's job; this procedure refuses to
-- start while the `online-mode` property is true) and no deflate (SQL has no deflate, so outbound packets are never compressed: it refuses to start while
-- `network-compression-threshold` is not -1).  Run `select mc.configure_dev_server();` first, it sets both.
-- Not done: idle-socket timeouts (a silent connection stays until the client or the game's keep-alive timeout closes it) and a limit on write-buffer size.
-- Crash domain: a Python exception stops the procedure (the backend survives); a segfault in a C library would restart Postgres.

create extension if not exists plpython3u;

create table if not exists net.gateway_control (id int primary key default 1 check (id = 1), stop boolean not null default false, ticks bigint not null default 0,
                                                 last_tick_ms float8, max_tick_ms float8, late_ticks bigint not null default 0, connections int not null default 0);
insert into net.gateway_control default values on conflict do nothing;

create or replace procedure net.run(p_port int default 25565, p_max_ticks bigint default null, p_tick_ms int default 50, p_bind text default '0.0.0.0')
language plpython3u as $$
import socket, selectors, time, zlib

if plpy.execute("select mc.prop('online-mode') as v")[0]["v"] == "true":
    plpy.error("net.run is an offline-mode development gateway; set online-mode=false (select mc.configure_dev_server())")
if plpy.execute("select mc.prop('network-compression-threshold') as v")[0]["v"] != "-1":
    plpy.error("net.run cannot compress outbound packets (no deflate in SQL); set network-compression-threshold=-1 (select mc.configure_dev_server())")

MAX_FRAME = 2097151
tick_s = p_tick_ms / 1000.0
sel = selectors.DefaultSelector()
ls = socket.socket(); ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
ls.bind((p_bind, p_port)); ls.listen(4096); ls.setblocking(False)
sel.register(ls, selectors.EVENT_READ, None)

conns = {}          # id -> dict(sock, ip, inb, outb, thr, closing, last_rx, play)
next_id = 1

prep_connect = plpy.prepare("select net.on_connect($1, $2::inet)", ["bigint", "text"])
prep_disc    = plpy.prepare("select net.on_disconnect($1)", ["bigint"])
prep_inbox   = plpy.prepare("insert into net.inbox (conn_id, payload) select c, p from unnest($1::bigint[], $2::bytea[]) as u(c, p)", ["bigint[]", "bytea[]"])
prep_tick    = plpy.prepare("select mc.server_tick() as t", [])
prep_drain   = plpy.prepare("select conn_id, data, close from net.drain_outbox()", [])
prep_comp    = plpy.prepare("select conn_id, compression from net.conn where compression >= 0", [])
prep_ctl     = plpy.prepare("update net.gateway_control set ticks = ticks + $4, last_tick_ms = $1, max_tick_ms = greatest(coalesce(max_tick_ms, 0), $5), late_ticks = late_ticks + $2, connections = $3 returning stop", ["float8", "int", "int", "int", "float8"])
prep_pending = plpy.prepare("select net.gateway_pending($1) as p", ["bigint"])
prep_ctlrows = plpy.prepare("select conn_id, ctl_seq, state from net.gateway_ctl($1)", ["bigint"])
last_ctl = 0

# the urgent chat lane (sql/801): packet ids of the serverbound frames it has to tell apart; disabled when net.urgent_chat does not exist
urgent_ok = False
try:
    r = plpy.execute("select mc.sid('chat') as chat, mc.sid('chat_command') as c1, mc.sid('chat_command_signed') as c2, mc.sid('client_tick_end') as n1, mc.sid('move_player_pos') as n2, "
                     "mc.sid('move_player_pos_rot') as n3, mc.sid('move_player_rot') as n4, mc.sid('move_player_status_only') as n5, to_regprocedure('net.urgent_chat(bigint[],bytea[])') is not null as ok")[0]
    if r["ok"] and None not in (r["chat"], r["c1"], r["c2"], r["n1"], r["n2"], r["n3"], r["n4"], r["n5"]):
        U_CHAT, U_CMD, U_NEUTRAL = r["chat"], (r["c1"], r["c2"]), (r["n1"], r["n2"], r["n3"], r["n4"], r["n5"])
        U_TICK_END, U_POS, U_POSROT = r["n1"], r["n2"], r["n3"]
        try:
            extra = plpy.execute("select case when to_regprocedure('net.urgent_neutral_play_ids()') is not null then net.urgent_neutral_play_ids() end as a")[0]["a"] or []
        except Exception:
            extra = []
        U_NEUTRAL = frozenset(U_NEUTRAL) | (frozenset(extra) - {U_CHAT} - frozenset(U_CMD))
        prep_urgent = plpy.prepare("select coalesce(array_to_string(net.urgent_chat($1, $2), ','), '') as u", ["bigint[]", "bytea[]"])
        urgent_ok = True
except Exception:
    urgent_ok = False
URGENT_RESERVE_S, URGENT_MAX = 0.004, 4
urgent_cost = 0.002
urgent_runs = 0
urgent_want = False
lean_n, lean_late, lean_max = 0, 0, 0.0

def varint_at(b, o):
    """(value, next offset) or None when the buffer ends inside the VarInt; raises ValueError when it is longer than 5 bytes"""
    v = shift = 0
    for i in range(5):
        if o + i >= len(b): return None
        c = b[o + i]; v |= (c & 0x7F) << shift
        if not c & 0x80: return v, o + i + 1
        shift += 7
    raise ValueError("VarInt too long")

def frame_pid(b):
    v = 0
    for i in range(3):
        if i >= len(b): return None
        v |= (b[i] & 0x7F) << (7 * i)
        if not b[i] & 0x80: return v
    return None

def urgent_candidates():
    """Indices into ids/payloads of the chat frames that may be handled now: no command ahead of them (any connection), nothing but chat or a neutral kind (client_tick_end, movement and the
    kinds of net.urgent_neutral_play_ids) ahead of them from their own connection.  Whether a connection is in play is the database's to say (net.urgent_chat hands the others back)."""
    taken, blocked = [], set()
    for i in range(len(ids)):
        pid = frame_pid(payloads[i]); cid = ids[i]
        if pid is None: blocked.add(cid)
        elif pid in U_CMD: break
        elif pid == U_CHAT:
            if cid not in blocked: taken.append(i)
        elif pid not in U_NEUTRAL: blocked.add(cid)
    return taken

def drop_idle_tick_ends():
    """The Rust gateway's skip_tick_end: client_tick_end frames of connections in play with fewer than two position packets in this tick are not given to the database (sql/800: it
    ignores them), so that idle players leave the inbox empty and the tick lean."""
    if not urgent_ok or U_TICK_END not in [frame_pid(b) for b in payloads]: return
    pos = {}
    for cid, b in zip(ids, payloads):
        pid = frame_pid(b)
        if pid == U_POS or pid == U_POSROT: pos[cid] = pos.get(cid, 0) + 1
    keep = [i for i in range(len(ids)) if not (frame_pid(payloads[i]) == U_TICK_END and pos.get(ids[i], 0) < 2 and conns.get(ids[i], {}).get("play"))]
    if len(keep) != len(ids):
        ids[:] = [ids[i] for i in keep]; payloads[:] = [payloads[i] for i in keep]

def run_urgent(deadline):
    nonlocal urgent_runs, urgent_cost
    if urgent_runs >= URGENT_MAX or time.perf_counter() + urgent_cost + URGENT_RESERVE_S > deadline: return
    taken = urgent_candidates()
    if not taken: return
    t = time.perf_counter()
    try:
        un = plpy.execute(prep_urgent, [[ids[i] for i in taken], [payloads[i] for i in taken]])[0]["u"]
        unhandled = set(int(x) for x in un.split(",") if x.strip())
        rows = list(plpy.execute(prep_drain, []))
        plpy.commit()
    except plpy.SPIError as e:
        plpy.rollback(); urgent_runs = URGENT_MAX
        plpy.notice("net.run: urgent chat run failed and was rolled back: %s" % e)
        return
    handled = set(taken[k] for k in range(len(taken)) if (k + 1) not in unhandled)
    keep_ids = [x for i, x in enumerate(ids) if i not in handled]; keep_pl = [x for i, x in enumerate(payloads) if i not in handled]
    ids[:] = keep_ids; payloads[:] = keep_pl
    urgent_runs += 1
    urgent_cost = 0.7 * urgent_cost + 0.3 * (time.perf_counter() - t)
    for row in rows:
        c = conns.get(row["conn_id"])
        if c is None: continue
        if row["data"]: c["outb"] += row["data"]
        if row["close"]: c["closing"] = True
    for cid in set(r["conn_id"] for r in rows): flush(cid)

def drop(cid, notify=True):
    c = conns.pop(cid, None)
    if c is None: return
    try: sel.unregister(c["sock"])
    except Exception: pass
    try: c["sock"].close()
    except Exception: pass
    if notify: dropped.append(cid)

def update_events(cid):
    c = conns.get(cid)
    if c is None: return
    ev = selectors.EVENT_READ | (selectors.EVENT_WRITE if c["outb"] else 0)
    try: sel.modify(c["sock"], ev, cid)
    except Exception: pass

def flush(cid):
    c = conns.get(cid)
    if c is None or not c["outb"]: return
    try:
        n = c["sock"].send(c["outb"]); del c["outb"][:n]
    except (BlockingIOError, InterruptedError): pass
    except OSError: drop(cid); return
    if not c["outb"] and c["closing"]: drop(cid, notify=False); return
    update_events(cid)

t0 = time.perf_counter(); tick = 0
dropped = []
while True:
    tick += 1
    deadline = t0 + tick * tick_s
    now = time.perf_counter()
    late = 0
    if now > deadline + 5 * tick_s:          # far behind (a long pause): do not try to catch up with a burst of ticks
        t0 = now - tick * tick_s; deadline = now
    elif now > deadline:
        late = 1
    ids, payloads, accepted = [], [], []
    dropped = []
    urgent_runs = 0; urgent_want = False
    # ---- I/O until the tick is due.  ALWAYS one pass over the ready sockets, even when the tick is already late: a loop that overruns must not stop reading
    # (it used to break out at once when `left <= 0`, so under sustained overload no socket was ever read, keep-alive answers sat in the kernel buffers and the
    # server kicked every player for not answering: docs/SOAK.md)
    first_pass = True
    while True:
        left = deadline - time.perf_counter()
        if left <= 0 and not first_pass: break
        first_pass = False
        for key, mask in sel.select(timeout=max(left, 0.0)):
            if key.data is None:
                try:
                    while True:
                        s, addr = ls.accept(); s.setblocking(False); s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                        cid = next_id; next_id += 1
                        conns[cid] = {"sock": s, "ip": addr[0], "inb": bytearray(), "outb": bytearray(), "thr": -1, "closing": False, "last_rx": time.time(), "play": False}
                        sel.register(s, selectors.EVENT_READ, cid); accepted.append(cid)
                except BlockingIOError: pass
                continue
            cid = key.data; c = conns.get(cid)
            if c is None: continue
            if mask & selectors.EVENT_WRITE: flush(cid)
            if not (mask & selectors.EVENT_READ) or cid not in conns: continue
            try: data = c["sock"].recv(65536)
            except (BlockingIOError, InterruptedError): continue
            except OSError: data = b""
            if not data: drop(cid); continue
            c["last_rx"] = time.time()
            b = c["inb"]; b += data; pos = 0
            try:
                while True:
                    r = varint_at(b, pos)
                    if r is None: break
                    ln, p = r
                    if ln == 0 or ln > MAX_FRAME: raise ValueError("bad frame length %d" % ln)
                    if p + ln > len(b): break
                    body = bytes(b[p:p + ln]); pos = p + ln
                    if c["thr"] >= 0:                     # compression on: [data length][zlib data or the raw packet]
                        dl, q = varint_at(body, 0)
                        if dl == 0: body = body[q:]
                        else:
                            if dl > 8388608: raise ValueError("inflated size too large")
                            body = zlib.decompress(body[q:])
                            if len(body) != dl: raise ValueError("inflated size mismatch")
                    ids.append(cid); payloads.append(body)
                    if urgent_ok and frame_pid(body) == U_CHAT: urgent_want = True
            except Exception as e:
                plpy.notice("net.run: closing connection %s: %s" % (cid, e)); drop(cid); continue
            del b[:pos]
        if urgent_want:
            urgent_want = False
            run_urgent(deadline)
    # ---- database work for this tick
    t_start = time.perf_counter()
    try:
        drop_idle_tick_ends()
        lean = not accepted and not dropped and not ids
        for cid in accepted:
            if cid in conns: plpy.execute(prep_connect, [cid, conns[cid]["ip"]])
        for cid in dropped: plpy.execute(prep_disc, [cid])
        dropped = []
        if ids: plpy.execute(prep_inbox, [ids, payloads])
        plpy.execute(prep_tick, [])
        pend = plpy.execute(prep_pending, [last_ctl])[0]["p"]
        pending = 1 if not lean else pend & 1
        if pend & 2:
            for row in plpy.execute(prep_ctlrows, [last_ctl]):
                last_ctl = max(last_ctl, row["ctl_seq"])
                c = conns.get(row["conn_id"])
                if c is not None: c["play"] = row["state"] == "play"
        if pending:
            for row in plpy.execute(prep_drain, []):
                c = conns.get(row["conn_id"])
                if c is None: continue
                if row["data"]: c["outb"] += row["data"]
                if row["close"]: c["closing"] = True
            for row in plpy.execute(prep_comp, []):
                c = conns.get(row["conn_id"])
                if c is not None: c["thr"] = row["compression"]
        ms = (time.perf_counter() - t_start) * 1000.0
        lean_n += 1; lean_late += late; lean_max = max(lean_max, ms)
        if not lean or pending or lean_n >= 10:
            stop = plpy.execute(prep_ctl, [ms, lean_late, len(conns), lean_n, lean_max])[0]["stop"]
            lean_n, lean_late, lean_max = 0, 0, 0.0
        else:
            stop = False
        plpy.commit()
    except plpy.SPIError as e:
        plpy.rollback()
        plpy.notice("net.run: tick %d failed and was rolled back: %s" % (tick, e))
        stop = False
    for cid in list(conns.keys()): flush(cid)
    if stop or (p_max_ticks is not None and tick >= p_max_ticks): break

for cid in list(conns.keys()): drop(cid, notify=False)
ls.close()
$$;
