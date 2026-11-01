#!/usr/bin/env python3
"""A local stand-in for Mojang's session server, for the online-mode tests (the real one is never called).

  POST /session/minecraft/join       the CLIENT announces "I am joining the server whose hash is X": {"accessToken","selectedProfile","serverId"} -> 204
  GET  /session/minecraft/hasJoined  the SERVER asks "did <username> join <serverId>?": 200 + profile once, then 204 (a join answers once, like a real session)
  GET  /_log                         every hasJoined query seen (the tests count them: the gateway must ask exactly once per login)
Behaviour by user name:  Down*  -> 503 on hasJoined;  Slow* -> sleeps 6 s before answering;  Quirk* -> the profile comes back with the name's case changed;
                         Forbidden* -> 403;  anything else is a normal profile.  Profiles are fixed per name (uuid, textures property with a signature).
usage: stub_mojang.py PORT            (prints "ready" when listening; stops on SIGTERM)"""
import base64, hashlib, json, sys, threading, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

lock = threading.Lock()
joined = {}          # (profile id hex, serverId) -> True, consumed by the first successful hasJoined
queries = []         # (username, serverId, outcome)

def profile_id(name):          # the online uuid of a name: deliberately not the offline (version 3) uuid
    return uuid.uuid5(uuid.NAMESPACE_DNS, "stub.mojang/" + name.lower()).hex

def properties(name):
    tex = base64.b64encode(json.dumps({"timestamp": 1, "profileId": profile_id(name), "profileName": name,
                                        "textures": {"SKIN": {"url": "http://textures.example/" + name.lower()}}}).encode()).decode()
    sig = base64.b64encode(hashlib.sha512(tex.encode()).digest() * 8).decode()[:684]      # Mojang's signatures are 684 characters
    return [{"name": "textures", "value": tex, "signature": sig}]

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def _send(self, code, body=None):
        self.send_response(code)
        if body is not None:
            data = json.dumps(body).encode()
            self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(data)))
            self.end_headers(); self.wfile.write(data)
        else:
            self.send_header("Content-Length", "0"); self.end_headers()

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(n) or b"{}")
        if urlparse(self.path).path == "/session/minecraft/join":
            with lock:
                joined[(body["selectedProfile"], body["serverId"])] = True
            return self._send(204)
        self._send(404)

    def do_GET(self):
        u = urlparse(self.path); q = parse_qs(u.query)
        if u.path == "/_log":
            with lock:
                return self._send(200, [list(x) for x in queries])
        if u.path != "/session/minecraft/hasJoined":
            return self._send(404)
        name = q.get("username", [""])[0]; sid = q.get("serverId", [""])[0]
        if name.startswith("Slow"): time.sleep(6)
        if name.startswith("Down"):
            with lock: queries.append((name, sid, "503"))
            return self._send(503)
        if name.startswith("Forbidden"):
            with lock: queries.append((name, sid, "403"))
            return self._send(403)
        with lock:
            ok = joined.pop((profile_id(name), sid), None)
            queries.append((name, sid, "200" if ok else "204"))
        if not ok:
            return self._send(204)
        shown = name.swapcase() if name.startswith("Quirk") else name
        self._send(200, {"id": profile_id(name), "name": shown, "properties": properties(name)})

if __name__ == "__main__":
    ThreadingHTTPServer.request_queue_size = 512      # the default backlog of 5 resets connections when many clients join at once
    srv = ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H)
    srv.daemon_threads = True
    print("ready", flush=True)
    srv.serve_forever()
