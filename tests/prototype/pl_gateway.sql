-- Prototype: the whole gateway as a stored procedure inside PostgreSQL (untrusted PL/Python).
-- Offline-mode echo only: it measures the architecture, not Minecraft behaviour.
create extension if not exists plpython3u;
create schema if not exists net;
drop table if exists net.inbox, net.outbox, net.tick_log;
create unlogged table net.inbox  (tick bigint, conn_id int, body bytea);
create unlogged table net.outbox (conn_id int, data bytea);
create table net.tick_log (tick bigint, conns int, frames_in int, bytes_out int,
                           recv_ms float8, db_ms float8, send_ms float8, busy_ms float8);

-- stand-in for mc.tick(): decode happens in SQL; here, consume the inbox and answer every inbound frame with one framed reply
create or replace function net.tick(t bigint) returns void language sql as $$
  with consumed as (delete from net.inbox returning conn_id, body)
  insert into net.outbox
  select conn_id, string_agg(set_byte('\x00'::bytea,0,length(body)+1) || body, ''::bytea)
  from consumed group by conn_id;
$$;

create or replace procedure net.run(port int, max_ticks int, tick_ms int default 50)
language plpython3u as $$
import socket, selectors, time
tick_s = tick_ms / 1000.0
sel = selectors.DefaultSelector()
ls = socket.socket(); ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
ls.bind(("127.0.0.1", port)); ls.listen(8192); ls.setblocking(False)
sel.register(ls, selectors.EVENT_READ, None)
conns = {}      # conn_id -> [sock, inbuf(bytearray), outbuf(bytearray)]
by_sock = {}
next_id = 1
ins  = plpy.prepare("insert into net.inbox select $1, c, b from unnest($2::int[], $3::bytea[]) u(c,b)", ["bigint","int[]","bytea[]"])
tk   = plpy.prepare("select net.tick($1)", ["bigint"])
drn  = plpy.prepare("with d as (delete from net.outbox returning conn_id, data) select conn_id, data from d", [])
logp = plpy.prepare("insert into net.tick_log values ($1,$2,$3,$4,$5,$6,$7,$8)", ["bigint","int","int","int","float8","float8","float8","float8"])
t0 = time.perf_counter()
for tick in range(1, max_ticks + 1):
    deadline = t0 + tick * tick_s
    ids, bodies = [], []
    ts = time.perf_counter(); wait = 0.0
    while True:
        left = deadline - time.perf_counter()
        if left <= 0: break
        w0 = time.perf_counter(); ev = sel.select(timeout=left); wait += time.perf_counter() - w0
        for key, _ in ev:
            if key.data is None:
                try:
                    while True:
                        s, _a = ls.accept(); s.setblocking(False); s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                        cid = next_id; next_id += 1
                        conns[cid] = [s, bytearray(), bytearray()]; sel.register(s, selectors.EVENT_READ, cid)
                except BlockingIOError: pass
            else:
                cid = key.data; c = conns.get(cid)
                try: data = c[0].recv(65536)
                except (BlockingIOError, InterruptedError): continue
                except OSError: data = b""
                if not data:
                    sel.unregister(c[0]); c[0].close(); del conns[cid]; continue
                b = c[1]; b += data; pos = 0; n = len(b)
                while pos < n:                      # frame split: 1-byte VarInt length (frames < 128 bytes in this prototype)
                    ln = b[pos]
                    if pos + 1 + ln > n: break
                    ids.append(cid); bodies.append(bytes(b[pos+1:pos+1+ln])); pos += 1 + ln
                del b[:pos]
    t1 = time.perf_counter()
    if ids: plpy.execute(ins, [tick, ids, bodies])
    plpy.execute(tk, [tick])
    out = plpy.execute(drn, [])
    nbytes = 0
    t2 = time.perf_counter()
    for r in out:
        c = conns.get(r["conn_id"])
        if c is None: continue
        c[2] += r["data"]; nbytes += len(r["data"])
    for c in conns.values():
        if c[2]:
            try: sent = c[0].send(c[2]); del c[2][:sent]
            except (BlockingIOError, InterruptedError): pass
            except OSError: pass
    t3 = time.perf_counter()
    plpy.execute(logp, [tick, len(conns), len(ids), nbytes, (t1-ts-wait)*1000, (t2-t1)*1000, (t3-t2)*1000, (t3-ts-wait)*1000])
    plpy.commit()
for c in conns.values(): c[0].close()
ls.close()
$$;
