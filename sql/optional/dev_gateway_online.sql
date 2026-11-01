-- Reference implementation of the production gateway's online-mode contract, as database code (untrusted PL/Python): net.run_online(port).
-- It exists so the SQL half of online mode (sql/600, sql/601) and the wire protocol are exercised end to end here, with the real RSA/AES of OpenSSL (Python's
-- `cryptography`), before and independently of the Rust gateway (gateway/), which implements exactly the same contract.  Same scope limits as net.run
-- (sql/optional/dev_gateway.sql): one backend, no per-IP limits, no idle timeouts.  Applied by `tools/migrate.sh --dev-gateway`.
--
-- Per 50 ms tick, in this order (one transaction):
--   accepted sockets   -> net.on_connect(id, ip)
--   inbound frames     -> one INSERT into net.inbox   (inflated if the connection's compression is on; the frame that answers an encryption request is NOT inserted)
--   key responses      -> net.auth_begun(ids), session checks start in worker threads
--   session verdicts   -> insert into net.auth_result;  net.apply_auth_results()
--   mc.server_tick()
--   closed sockets     -> net.on_disconnect(id)
--   outbox             -> net.drain_outbox(): bytes (encrypted when the connection is) are appended to each socket's write buffer
--   control            -> net.gateway_ctl(last_seq): compression threshold, play state, "await_key" with the 4-byte challenge
-- Settings: net.setting 'session_url' (default https://sessionserver.mojang.com), 'session_timeout_s' (default 5).

create extension if not exists plpython3u;

create or replace procedure net.run_online(p_port int default 25565, p_max_ticks bigint default null, p_tick_ms int default 50, p_bind text default '0.0.0.0')
language plpython3u as $$
import socket, selectors, time, zlib, threading, queue, hashlib, json, urllib.request, urllib.error, urllib.parse
from cryptography.hazmat.primitives.asymmetric import rsa, padding
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms
try:
    from cryptography.hazmat.decrepit.ciphers.modes import CFB8        # where newer versions keep it
except ImportError:
    from cryptography.hazmat.primitives.ciphers.modes import CFB8

def setting(k, d):
    r = plpy.execute(plpy.prepare("select net.setting($1) as v", ["text"]), [k])[0]["v"]
    return d if r is None else r

session_url = setting("session_url", "https://sessionserver.mojang.com").rstrip("/")
session_timeout = float(setting("session_timeout_s", "5"))
key_pkt = plpy.execute("select net.pkt('login', 'serverbound', 'minecraft:key') as id")[0]["id"]

try:
    priv = rsa.generate_private_key(public_exponent=65537, key_size=1024)      # vanilla's size
except ValueError:
    priv = rsa.generate_private_key(public_exponent=65537, key_size=2048)
pub_der = priv.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
plpy.execute(plpy.prepare("insert into net.server_key (id, public_der) values (1, $1) on conflict (id) do update set public_der = excluded.public_der, updated_at = now()", ["bytea"]), [pub_der])
plpy.execute("select net.gateway_start()")          # stale connections of a previous process (their ids would be reused by this one)
plpy.commit()

MAX_FRAME = 2097151
tick_s = p_tick_ms / 1000.0
sel = selectors.DefaultSelector()
ls = socket.socket(); ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
ls.bind((p_bind, p_port)); ls.listen(4096); ls.setblocking(False)
sel.register(ls, selectors.EVENT_READ, None)

conns = {}
next_id = 1
verdicts = queue.Queue()                  # (conn_id, ok, reason, uuid, name, properties) from the worker threads
limiter = threading.Semaphore(32)         # bounded concurrency towards the session server

prep_connect = plpy.prepare("select net.on_connect($1, $2::inet)", ["bigint", "text"])
prep_disc    = plpy.prepare("select net.on_disconnect($1)", ["bigint"])
prep_inbox   = plpy.prepare("insert into net.inbox (conn_id, payload) select c, p from unnest($1::bigint[], $2::bytea[]) as u(c, p)", ["bigint[]", "bytea[]"])
prep_begun   = plpy.prepare("select net.auth_begun($1::bigint[])", ["bigint[]"])
prep_verdict = plpy.prepare("insert into net.auth_result (conn_id, ok, reason, uuid, name, properties) values ($1, $2, $3, $4::uuid, $5, $6::jsonb)", ["bigint", "boolean", "text", "text", "text", "text"])
prep_apply   = plpy.prepare("select net.apply_auth_results()", [])
prep_tick    = plpy.prepare("select mc.server_tick()", [])
prep_drain   = plpy.prepare("select conn_id, data, close from net.drain_outbox()", [])
prep_ctl     = plpy.prepare("select conn_id, ctl_seq, state, compression, await_key, name, verify_token from net.gateway_ctl($1)", ["bigint"])
prep_stat    = plpy.prepare("update net.gateway_control set ticks = ticks + 1, last_tick_ms = $1, max_tick_ms = greatest(coalesce(max_tick_ms, 0), $1), late_ticks = late_ticks + $2, connections = $3 returning stop", ["float8", "int", "int"])

def varint_at(b, o, maxlen=5):
    v = shift = 0
    for i in range(maxlen):
        if o + i >= len(b): return None
        c = b[o + i]; v |= (c & 0x7F) << shift
        if not c & 0x80: return v, o + i + 1
        shift += 7
    raise ValueError("VarInt too long")

def read_bytes_field(b, o, cap=512):
    r = varint_at(b, o)
    if r is None: raise ValueError("truncated byte array")
    n, o = r
    if n > cap or o + n > len(b): raise ValueError("bad byte array")
    return bytes(b[o:o + n]), o + n

def server_hash(secret):
    d = hashlib.sha1(b"" + secret + pub_der).digest()
    return format(int.from_bytes(d, "big", signed=True), "x")       # Java's BigInteger.toString(16): signed, minimal

def session_check(cid, name, shash):
    """worker thread: Mojang's hasJoined.  200 + profile = ok; 204 / 4xx = invalid session; 5xx, timeout, network error = unavailable."""
    with limiter:
        url = "%s/session/minecraft/hasJoined?%s" % (session_url, urllib.parse.urlencode({"username": name, "serverId": shash}))
        try:
            with urllib.request.urlopen(url, timeout=session_timeout) as r:
                body = r.read()
                if r.status == 200 and body:
                    p = json.loads(body)
                    h = p["id"]; uuid = "%s-%s-%s-%s-%s" % (h[0:8], h[8:12], h[12:16], h[16:20], h[20:32])
                    verdicts.put((cid, True, None, uuid, p["name"], json.dumps(p.get("properties", []))))
                else:
                    verdicts.put((cid, False, "invalid", None, None, "[]"))
        except urllib.error.HTTPError as e:
            verdicts.put((cid, False, "unavailable" if e.code >= 500 or e.code == 429 else "invalid", None, None, "[]"))
        except Exception:
            verdicts.put((cid, False, "unavailable", None, None, "[]"))

def drop(cid, notify=True, why=""):
    c = conns.pop(cid, None)
    if c is None: return
    if why: plpy.notice("net.run_online: connection %s dropped: %s" % (cid, why))
    try: sel.unregister(c["sock"])
    except Exception: pass
    try: c["sock"].close()
    except Exception: pass
    if notify: dropped.append(cid)

def update_events(cid):
    c = conns.get(cid)
    if c is None: return
    try: sel.modify(c["sock"], selectors.EVENT_READ | (selectors.EVENT_WRITE if c["outb"] else 0), cid)
    except Exception: pass

def flush(cid):
    c = conns.get(cid)
    if c is None or not c["outb"]: return
    try:
        n = c["sock"].send(c["outb"]); del c["outb"][:n]
    except (BlockingIOError, InterruptedError): pass
    except OSError: drop(cid, why="write error"); return
    if not c["outb"] and c["closing"]: drop(cid, notify=False, why="closed after its last bytes (the database asked for it)"); return
    update_events(cid)

def handle_key(cid, c, body):
    """the frame that answers the encryption request: decrypt, check the challenge, switch to AES-128-CFB8 both ways, start the session check"""
    pid = varint_at(body, 0)
    if pid is None or pid[0] != key_pkt: raise ValueError("expected the key packet")
    keybytes, o = read_bytes_field(body, pid[1])
    chall, o = read_bytes_field(body, o)
    secret = priv.decrypt(keybytes, padding.PKCS1v15())
    if len(secret) != 16: raise ValueError("shared secret is not 16 bytes")
    if priv.decrypt(chall, padding.PKCS1v15()) != c["await"][0]: raise ValueError("verify token mismatch")
    cipher = lambda: Cipher(algorithms.AES(secret), CFB8(secret))
    c["enc"] = cipher().encryptor(); c["dec"] = cipher().decryptor()
    name = c["await"][1]; c["await"] = None
    begun.append(cid)
    threading.Thread(target=session_check, args=(cid, name, server_hash(secret)), daemon=True).start()

t0 = time.perf_counter(); tick = 0; last_ctl = 0
dropped = []; begun = []
while True:
    tick += 1
    deadline = t0 + tick * tick_s
    now = time.perf_counter(); late = 0
    if now > deadline + 5 * tick_s: t0 = now - tick * tick_s; deadline = now
    elif now > deadline: late = 1
    ids, payloads, accepted = [], [], []
    dropped = []; begun = []
    while True:
        left = deadline - time.perf_counter()
        if left <= 0: break
        for key, mask in sel.select(timeout=left):
            if key.data is None:
                try:
                    while True:
                        s, addr = ls.accept(); s.setblocking(False); s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                        cid = next_id; next_id += 1
                        conns[cid] = {"sock": s, "ip": addr[0], "inb": bytearray(), "outb": bytearray(), "thr": -1, "closing": False,
                                      "await": None, "enc": None, "dec": None, "play": False}
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
            if not data: drop(cid, why="the client closed the socket"); continue
            if c["dec"] is not None: data = c["dec"].update(data)
            b = c["inb"]; b += data; pos = 0
            try:
                while True:
                    r = varint_at(b, pos, 3)
                    if r is None: break
                    ln, p = r
                    if ln == 0 or ln > MAX_FRAME or (not c["play"] and ln > 65536): raise ValueError("bad frame length %d" % ln)
                    if p + ln > len(b): break
                    body = bytes(b[p:p + ln]); pos = p + ln
                    if c["await"] is not None:                      # online mode: this frame is the key response
                        handle_key(cid, c, body)
                        if c["dec"] is not None and pos < len(b):    # bytes already buffered after it are ciphertext
                            b[pos:] = c["dec"].update(bytes(b[pos:]))
                        continue
                    if c["thr"] >= 0:
                        dl, q = varint_at(body, 0)
                        if dl == 0: body = body[q:]
                        else:
                            if dl < c["thr"] or dl > 8388608: raise ValueError("bad data length")
                            body = zlib.decompress(body[q:])
                            if len(body) != dl: raise ValueError("inflated size mismatch")
                    ids.append(cid); payloads.append(body)
            except Exception as e:
                plpy.notice("net.run_online: closing connection %s: %s" % (cid, e)); drop(cid); continue
            del b[:pos]
    t_start = time.perf_counter()
    try:
        for cid in accepted:
            if cid in conns: plpy.execute(prep_connect, [cid, conns[cid]["ip"]])
        if ids: plpy.execute(prep_inbox, [ids, payloads])
        if begun: plpy.execute(prep_begun, [begun])
        while True:
            try: v = verdicts.get_nowait()
            except queue.Empty: break
            if v[0] in conns: plpy.execute(prep_verdict, list(v))
        plpy.execute(prep_apply, [])
        plpy.execute(prep_tick, [])
        for cid in dropped: plpy.execute(prep_disc, [cid])
        dropped = []
        for row in plpy.execute(prep_drain, []):
            c = conns.get(row["conn_id"])
            if c is None: continue
            if row["data"]: c["outb"] += (c["enc"].update(bytes(row["data"])) if c["enc"] is not None else bytes(row["data"]))
            if row["close"]: c["closing"] = True
        for row in plpy.execute(prep_ctl, [last_ctl]):
            last_ctl = max(last_ctl, row["ctl_seq"])
            c = conns.get(row["conn_id"])
            if c is None: continue
            c["thr"] = row["compression"]
            c["play"] = row["state"] == "play"
            if row["await_key"]: c["await"] = (bytes(row["verify_token"]), row["name"])
        ms = (time.perf_counter() - t_start) * 1000.0
        stop = plpy.execute(prep_stat, [ms, late, len(conns)])[0]["stop"]
        plpy.commit()
    except plpy.SPIError as e:
        plpy.rollback()
        plpy.notice("net.run_online: tick %d failed and was rolled back: %s" % (tick, e))
        stop = False
    for cid in list(conns.keys()): flush(cid)
    if stop or (p_max_ticks is not None and tick >= p_max_ticks): break

for cid in list(conns.keys()): drop(cid, notify=False)
ls.close()
$$;
