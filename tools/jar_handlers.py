#!/usr/bin/env python3
"""Classify the serverbound play handlers of ServerGamePacketListenerImpl (javap -c -p output) for the urgent chat lane.
For each public handleX method: does it queue its body on the main thread (PacketUtils.ensureRunningOnSameThread), and which chat-related members do it and the lambdas
it creates touch.  usage: jar_handlers.py javap.txt"""
import re, sys

text = open(sys.argv[1]).read()
# split into methods: a method header is a line with two-space indent that ends with ';' and is followed by '    Code:'
methods = {}
cur = None
for line in text.splitlines():
    m = re.match(r"^  (?:(?:public|private|protected|static|final|synthetic|abstract)\s+)*[\w.$<>\[\],? ]+\s+([\w$<>]+)\((.*)\)( throws [\w., ]+)?;$", line)
    if m and not line.startswith("   "):
        cur = line.strip()
        methods[cur] = []
        continue
    if cur is not None:
        methods[cur].append(line)

def body(sig):
    return "\n".join(methods[sig])

by_name = {}
for sig in methods:
    n = re.search(r"([\w$<>]+)\(", sig).group(1)
    by_name.setdefault(n, []).append(sig)

CHAT = ["chatMessageChain", "lastSeenMessages", "signedMessageDecoder", "chatSession", "messageSignatureCache", "ChatVisiblity", "getChatVisibility", "broadcastChatMessage",
        "PlayerChatMessage", "sendPlayerChatMessage", "isChatMessageIllegal", "chatSpamThrottler", "tryHandleChat", "sendSystemMessage", "ChatType", "PlayerList.broadcast",
        "chatAck", "LastSeenMessages", "updateChatSession", "messageCounter", "sendChatMessage"]

def lambdas(b):
    return re.findall(r"invokedynamic.*?// InvokeDynamic #\d+:\w+:.*?", b) and re.findall(r"lambda\$[\w$]+", b)

rows = []
for n, sigs in sorted(by_name.items()):
    if not n.startswith("handle"):
        continue
    for sig in sigs:
        if "public" not in sig:
            continue
        b = body(sig)
        queued = "ensureRunningOnSameThread" in b
        lam = set(re.findall(r"(lambda\$[\w$]+)", b))
        lam_text = ""
        for l in lam:
            for s2 in by_name.get(l, []):
                lam_text += body(s2)
        allb = b + lam_text
        chat = sorted({c for c in CHAT if c in allb})
        calls = sorted(set(re.findall(r"// Method ([\w/$]+)\.([\w$<>]+):", allb)))
        short = sorted({"%s.%s" % (c.split("/")[-1], m) for c, m in calls if "ServerGamePacketListenerImpl" in c or "ServerPlayer" in c})
        rows.append((n, queued, chat, len(b.splitlines()), short))
for n, queued, chat, size, short in rows:
    print("%-34s main-thread-queued=%-5s chat-related=%s" % (n, queued, ",".join(chat) or "-"))
if "-v" in sys.argv:
    for n, queued, chat, size, short in rows:
        print("\n%s: %s" % (n, "; ".join(short)[:900]))
