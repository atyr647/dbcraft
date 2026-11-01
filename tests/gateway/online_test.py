#!/usr/bin/env python3
"""Online-mode end-to-end test: a client that performs the real encryption handshake against a gateway (the PL/Python reference gateway net.run_online, or the
Rust gateway) backed by the real database, with a local stub of Mojang's session server.

usage: online_test.py GATEWAY_PORT STUB_PORT PGPORT [--compression N]
It switches the server to online mode through SQL, runs every scenario, restores the settings, and exits non-zero on the first failed check group.

What a login looks like (the client side, as vanilla does it):  handshake(intent 2) -> hello(name, uuid) -> encryption_request(serverId, publicKey, challenge, true)
 -> [client: random 16-byte secret; POST /session/minecraft/join {accessToken, selectedProfile, serverId = signed-hex sha1(serverId + secret + publicKey)}]
 -> key(RSA(secret), RSA(challenge)) -> everything after this frame is AES-128-CFB8 with key = iv = secret, both directions
 -> [compression packet] -> login_finished(uuid, name, properties, sessionId) | login_disconnect(json) -> login_acknowledged -> configuration -> play
Requires Python's `cryptography` (OpenSSL) for the RSA/AES of the client."""
import argparse, hashlib, json, os, socket, struct, subprocess, sys, time, urllib.request, uuid, zlib
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import stub_mojang
from cryptography.hazmat.primitives.asymmetric import rsa, padding
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms
try:
    from cryptography.hazmat.decrepit.ciphers.modes import CFB8       # where newer versions keep it
except ImportError:
    from cryptography.hazmat.primitives.ciphers.modes import CFB8

REPORTS = os.environ.get("DBCRAFT_REPORTS", "/home/user/atyr647/adacraft/generated/26.3/reports")
PK = json.load(open(os.path.join(REPORTS, "packets.json")))
ID = {(st, d, n): e["protocol_id"] for st, dd in PK.items() for d, ps in dd.items() for n, e in ps.items()}
NAME = {(st, d, e["protocol_id"]): n for st, dd in PK.items() for d, ps in dd.items() for n, e in ps.items()}

def varint(n):
    n &= 0xFFFFFFFF; o = bytearray()
    while True:
        b = n & 0x7F; n >>= 7
        if n: o.append(b | 0x80)
        else: o.append(b); return bytes(o)
def string(s): b = s.encode(); return varint(len(b)) + b
def rvarint(b, o=0):
    v = sh = 0
    while True:
        c = b[o]; o += 1; v |= (c & 0x7F) << sh
        if not c & 0x80: return v, o
        sh += 7
def rstring(b, o):
    n, o = rvarint(b, o); return b[o:o + n].decode(), o + n
def rbytes(b, o):
    n, o = rvarint(b, o); return bytes(b[o:o + n]), o + n

def signed_hash(secret, pub):
    return format(int.from_bytes(hashlib.sha1(b"" + secret + pub).digest(), "big", signed=True), "x")

class Closed(Exception): pass

class Client:
    def __init__(self, port, timeout=8.0):
        self.s = socket.create_connection(("127.0.0.1", port)); self.s.settimeout(timeout)
        self.enc = self.dec = None; self.thr = -1; self.state = "handshake"; self.log = []
    def close(self): self.s.close()
    def _recv_exact(self, n):
        out = bytearray()
        while len(out) < n:
            c = self.s.recv(n - len(out))
            if not c: raise Closed()
            if self.dec: c = self.dec.update(c)
            out += c
        return bytes(out)
    def _recv_varint(self):
        v = sh = 0
        while True:
            c = self._recv_exact(1)[0]; v |= (c & 0x7F) << sh
            if not c & 0x80: return v
            sh += 7
    def recv(self):
        ln = self._recv_varint(); raw = self._recv_exact(ln)
        if self.thr >= 0:
            dl, o = rvarint(raw)
            raw = raw[o:] if dl == 0 else zlib.decompress(raw[o:])
        pid, o = rvarint(raw)
        name = NAME.get((self.state if self.state != "login_ack" else "login", "clientbound", pid), "?")
        self.log.append(name)
        return name, raw[o:]
    def send_raw(self, data):
        self.s.sendall(self.enc.update(data) if self.enc else data)
    def send(self, name, body=b""):
        st = "login" if self.state in ("login", "login_ack") else self.state
        payload = varint(ID[(st, "serverbound", name)]) + body
        frame = (varint(len(payload) + 1) + b"\x00" + payload) if self.thr >= 0 else varint(len(payload)) + payload
        self.send_raw(frame)

def offline_uuid(name):
    h = bytearray(hashlib.md5(("OfflinePlayer:" + name).encode()).digest()); h[6] = (h[6] & 0x0F) | 0x30; h[8] = (h[8] & 0x3F) | 0x80
    return bytes(h)

def http(url, data=None):
    req = urllib.request.Request(url, data=json.dumps(data).encode() if data is not None else None, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=5) as r: return r.status, r.read()

def login(gw_port, stub_port, name, *, register_join=True, wrong_key=False, bad_token=False, secret_len=16, send_garbage=False, double_hello=False, to_play=False):
    """Runs a login; returns a dict: outcome 'finished' | 'disconnect' | 'closed', plus what was seen."""
    c = Client(gw_port); r = {"client": c, "outcome": None}
    c.s.sendall(varint(len(varint(0) + varint(777) + string("localhost") + b"\x63\xdd" + varint(2))) + varint(0) + varint(777) + string("localhost") + b"\x63\xdd" + varint(2))
    c.state = "login"
    hello = varint(ID[("login", "serverbound", "minecraft:hello")]) + string(name) + offline_uuid(name)
    c.s.sendall(varint(len(hello)) + hello)
    try:
        n, b = c.recv()
        if n == "minecraft:login_disconnect":
            r["outcome"] = "disconnect"; r["json"] = json.loads(rstring(b, 0)[0]); return r
        assert n == "minecraft:hello", "expected the encryption request, got " + n
        sid, o = rstring(b, 0); pub, o = rbytes(b, o); chall, o = rbytes(b, o); should = b[o] == 1
        r.update(server_id=sid, public_key=pub, challenge=chall, should_authenticate=should)
        if double_hello:
            c.s.sendall(varint(len(hello)) + hello)               # a second hello in the middle of the key exchange
            time.sleep(0.3)
            r["outcome"] = "closed"
            try: c.recv()
            except (Closed, ConnectionError, socket.timeout): pass
            return r
        if send_garbage:
            junk = varint(0x7f) + b"junk"
            c.s.sendall(varint(len(junk)) + junk)
            r["outcome"] = "closed"
            try: c.recv()
            except (Closed, ConnectionError, socket.timeout): pass
            return r
        secret = os.urandom(secret_len)
        pubkey = serialization.load_der_public_key(pub)
        if wrong_key:
            pubkey = rsa.generate_private_key(public_exponent=65537, key_size=1024).public_key()
        token = chall[::-1] if bad_token else chall
        if register_join:
            shash = signed_hash(secret, pub)
            http("http://127.0.0.1:%d/session/minecraft/join" % stub_port, {"accessToken": "t", "selectedProfile": stub_mojang.profile_id(name), "serverId": shash})
            r["hash"] = shash
        body = varint(ID[("login", "serverbound", "minecraft:key")])
        k = pubkey.encrypt(secret, padding.PKCS1v15()); t = pubkey.encrypt(token, padding.PKCS1v15())
        body += varint(len(k)) + k + varint(len(t)) + t
        c.s.sendall(varint(len(body)) + body)                      # this frame is plaintext: encryption starts right after it
        if secret_len == 16 and not wrong_key and not bad_token:
            cip = lambda: Cipher(algorithms.AES(secret), CFB8(secret))
            c.enc = cip().encryptor(); c.dec = cip().decryptor()
        else:
            c.enc = c.dec = None
        while True:
            n, b = c.recv()
            if n == "minecraft:login_compression": c.thr, _ = rvarint(b, 0)
            elif n == "minecraft:login_disconnect":
                r["outcome"] = "disconnect"; r["json"] = json.loads(rstring(b, 0)[0]); return r
            elif n == "minecraft:login_finished":
                u = b[:16]; nm, o = rstring(b, 16); cnt, o = rvarint(b, o); props = []
                for _ in range(cnt):
                    pn, o = rstring(b, o); pv, o = rstring(b, o); has = b[o]; o += 1; sig = None
                    if has: sig, o = rstring(b, o)
                    props.append({"name": pn, "value": pv, "signature": sig})
                r.update(outcome="finished", uuid=uuid.UUID(bytes=u), name=nm, properties=props, session_id=b[o:o + 16], raw=b)
                break
        if not to_play: return r
        c.send("minecraft:login_acknowledged"); c.state = "configuration"
        while True:
            n, b = c.recv()
            if n == "minecraft:select_known_packs": c.send("minecraft:select_known_packs", varint(0))
            elif n == "minecraft:keep_alive": c.send("minecraft:keep_alive", b)
            elif n == "minecraft:finish_configuration": break
        c.send("minecraft:finish_configuration"); c.state = "play"
        got = {}; end = time.time() + 2.0; loaded = False
        while time.time() < end:
            try: n, b = c.recv()
            except socket.timeout: break
            got.setdefault(n, []).append(b)
            if n == "minecraft:keep_alive": c.send("minecraft:keep_alive", b)
            elif n == "minecraft:player_position":
                _, o = rvarint(b, 0); c.send("minecraft:accept_teleportation", b[:o] + b[o:o + 24] + b[o + 48:o + 56])
                if not loaded: c.send("minecraft:player_loaded"); loaded = True
            elif n == "minecraft:chunk_batch_finished": c.send("minecraft:chunk_batch_received", struct.pack(">f", 20.0))
        r["play"] = got
        return r
    except (Closed, ConnectionError, socket.timeout) as e:
        r["outcome"] = r["outcome"] or "closed"; r["error"] = repr(e); return r

def psql(pgport, sql):
    p = subprocess.run(["psql", "-X", "-q", "-At", "-h", "/tmp", "-p", str(pgport), "-U", "postgres", "dbcraft", "-v", "ON_ERROR_STOP=1", "-c", sql], capture_output=True, text=True)
    if p.returncode: raise RuntimeError(p.stderr)
    return p.stdout.strip()

failures = []
def check(name, cond, extra=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(extra)))
    if not cond: failures.append(name)

def props_bytes(props):
    out = varint(len(props))
    for p in props:
        out += string(p["name"]) + string(p["value"]) + (b"\x01" + string(p["signature"]) if p["signature"] else b"\x00")
    return out

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("gw_port", type=int); ap.add_argument("stub_port", type=int); ap.add_argument("pg_port", type=int)
    ap.add_argument("--compression", type=int, default=-1)
    a = ap.parse_args()
    g, s, pg = a.gw_port, a.stub_port, a.pg_port
    psql(pg, "update mc.server_property set value = 'true' where key = 'online-mode'; update mc.server_property set value = '%d' where key = 'network-compression-threshold'; "
             "update mc.server_property set value = 'false' where key = 'white-list'; select net.sync_settings()" % a.compression)
    print("online mode on, compression threshold %d" % a.compression)
    try:
        print("--- successful login with a signed skin")
        r = login(g, s, "Skinned", to_play=True)
        check("login finishes", r["outcome"] == "finished", r)
        if r["outcome"] == "finished":
            check("the encryption request carries an empty server id and shouldAuthenticate=true", r["server_id"] == "" and r["should_authenticate"])
            check("public key is an X.509 RSA key", serialization.load_der_public_key(r["public_key"]).key_size in (1024, 2048))
            check("challenge is 4 bytes", len(r["challenge"]) == 4)
            check("uuid is Mojang's profile id, not the offline uuid", r["uuid"].hex == stub_mojang.profile_id("Skinned") and r["uuid"].bytes != offline_uuid("Skinned"))
            check("name is the profile's", r["name"] == "Skinned")
            expect = stub_mojang.properties("Skinned")
            check("login_finished carries the profile properties exactly", r["properties"] == expect, r["properties"])
            check("the properties are 1 texture with a 684-character signature", len(r["properties"]) == 1 and len(r["properties"][0]["signature"]) == 684)
            check("login_finished ends with a 16-byte session id", len(r["session_id"]) == 16)
            check("configuration and play were reached", "minecraft:login" in r.get("play", {}), list(r.get("play", {})))
            pie = r.get("play", {}).get("minecraft:player_info_update", [])
            check("the tab-list entry of the player carries the properties (skin)", any(props_bytes(expect) in b for b in pie), "player_info_update packets: %d" % len(pie))
            check("the tab-list entry carries the verified name and uuid", any(bytes.fromhex(stub_mojang.profile_id("Skinned")) + string("Skinned") in b for b in pie))
        r["client"].close()
        log = json.loads(urllib.request.urlopen("http://127.0.0.1:%d/_log" % s).read())
        mine = [q for q in log if q[0] == "Skinned"]
        check("the gateway asked the session server exactly once for that login", len(mine) == 1 and mine[0][2] == "200", mine)
        if mine and r.get("hash"):
            check("...with the hash the client computed independently (signed SHA-1 of serverId + secret + key)", mine[0][1] == r["hash"], (mine[0][1], r.get("hash")))

        print("--- the profile's name is adopted (vanilla uses Mojang's answer)")
        r = login(g, s, "Quirk1")
        check("login finishes with the name Mojang returned", r["outcome"] == "finished" and r["name"] == "Quirk1".swapcase(), r.get("name"))
        r["client"].close()

        print("--- session server verdicts")
        r = login(g, s, "NoJoin", register_join=False)
        check("no join registered -> multiplayer.disconnect.unverified_username", r["outcome"] == "disconnect" and r["json"] == {"translate": "multiplayer.disconnect.unverified_username"}, r)
        r["client"].close()
        r = login(g, s, "Forbidden1")
        check("403 -> multiplayer.disconnect.unverified_username", r["outcome"] == "disconnect" and r["json"] == {"translate": "multiplayer.disconnect.unverified_username"}, r)
        r["client"].close()
        r = login(g, s, "Down1")
        check("503 -> multiplayer.disconnect.authservers_down", r["outcome"] == "disconnect" and r["json"] == {"translate": "multiplayer.disconnect.authservers_down"}, r)
        r["client"].close()
        r = login(g, s, "Slow1")
        check("no answer within the timeout -> multiplayer.disconnect.authservers_down", r["outcome"] == "disconnect" and r["json"] == {"translate": "multiplayer.disconnect.authservers_down"}, r)
        r["client"].close()

        print("--- protocol violations close the connection, without a session query")
        before = len(json.loads(urllib.request.urlopen("http://127.0.0.1:%d/_log" % s).read()))
        for label, kw in (("a wrong verify token", dict(bad_token=True)), ("a secret encrypted with another key", dict(wrong_key=True)),
                          ("a 24-byte shared secret", dict(secret_len=24)), ("a frame that is not the key packet", dict(send_garbage=True)),
                          ("a second hello during the key exchange", dict(double_hello=True))):
            r = login(g, s, "Violator", register_join=False, **kw)
            check(label + " -> the connection is closed and no login finishes", r["outcome"] in ("closed", "disconnect") and r["outcome"] != "finished", r.get("outcome"))
            r["client"].close()
        after = len(json.loads(urllib.request.urlopen("http://127.0.0.1:%d/_log" % s).read()))
        check("none of them reached the session server", after == before, (before, after))

        print("--- nothing leaks in the database")
        time.sleep(1.0)
        left = psql(pg, "select count(*) from net.conn where state <> 'play'")
        check("no half-finished connection rows remain", left == "0", left)
        check("no unapplied verdicts and no connection waiting for a key", psql(pg, "select (select count(*) from net.auth_result) + (select count(*) from net.conn where await_key or auth_pending)") == "0")
    finally:
        psql(pg, "update mc.server_property set value = 'false' where key = 'online-mode'; update mc.server_property set value = '-1' where key = 'network-compression-threshold'; select net.sync_settings()")
    print("\n%s" % ("ALL ONLINE-MODE CHECKS PASSED" if not failures else "FAILED: " + "; ".join(failures)))
    sys.exit(1 if failures else 0)

if __name__ == "__main__":
    main()
