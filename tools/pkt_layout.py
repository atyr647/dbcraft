#!/usr/bin/env python3
"""Print the wire layout hints of Minecraft packet classes by reading their bytecode with javap (the classes are only READ, never run).

usage: tools/pkt_layout.py ClassName [ClassName ...]      e.g.  ServerboundChatPacket  'ServerboundMovePlayerPacket$Pos'
Classes are looked up under net/minecraft/network/protocol/{game,common,login,configuration,status} in the extracted inner jar:
  DBCRAFT_CLASSES (default /tmp/game-scratch/cls), made with
  unzip -o /tmp/jar-dl/server.jar META-INF/versions/26.3/server-26.3.jar -d X ; unzip -o X/META-INF/versions/26.3/server-26.3.jar 'net/minecraft/*' -d $DBCRAFT_CLASSES

For each class it lists, in order: record fields (the packet's data), the FriendlyByteBuf read/write calls of read()/write()/<init>(FriendlyByteBuf),
and the ByteBufCodecs / helper codec constants used when the codec is built with StreamCodec.composite.  Hints, not a decompiler: confirm with captured bytes.
"""
import os, re, subprocess, sys

root = os.environ.get("DBCRAFT_CLASSES", "/tmp/game-scratch/cls")
pkgs = ["game", "common", "login", "configuration", "status", "cookie", "ping"]

def javap(name):
    if "." in name:                                    # fully qualified: net.minecraft.network.chat.MessageSignature
        f = os.path.join(root, name.replace(".", "/") + ".class")
        if os.path.exists(f):
            r = subprocess.run(["javap", "-p", "-c", "-classpath", root, name], capture_output=True, text=True)
            return name, [l for l in r.stdout.splitlines() if "JAVA_TOOL" not in l]
    for p in pkgs:
        path = f"net.minecraft.network.protocol.{p}.{name}"
        f = os.path.join(root, path.replace(".", "/") + ".class")
        if os.path.exists(f):
            r = subprocess.run(["javap", "-p", "-c", "-classpath", root, path], capture_output=True, text=True)
            return path, [l for l in r.stdout.splitlines() if "JAVA_TOOL" not in l]
    return None, []

def short(sig):
    return sig.replace("net/minecraft/network/", "").replace("net/minecraft/", "").replace("java/lang/", "")

for name in sys.argv[1:]:
    path, lines = javap(name)
    if not path:
        print(f"== {name}: class not found under {root}"); continue
    print(f"== {path.split('protocol.')[-1]}")
    method = None
    out = []
    for l in lines:
        m = re.match(r"^  (?:public |private |protected |static |final )*[\w.$<>\[\], ]*?\s*([\w$<>]+)\((.*?)\)(?: throws.*)?;$", l)
        if re.match(r"^  \S", l) and l.strip().endswith(");") or re.match(r"^  static \{\};", l):
            method = l.strip()
        if re.match(r"^  (private|public|protected)? ?(final )?[\w.$<>\[\], ]+ \w+;$", l) and "(" not in l:
            out.append(("field", l.strip()))
        c = re.search(r"//\s*(Field|InterfaceMethod|Method)\s+(.*)", l)
        if c and method:
            body = c.group(2)
            if re.search(r"FriendlyByteBuf\.(read|write)\w+", body) or "ByteBufCodecs." in body or re.search(r"(Component|ComponentSerialization|NbtOps|Utf8String|ResourceLocation|Identifier|ItemStack|Vec3|BlockPos|UUIDUtil|GameType|FilterMask|LastSeen|MessageSignature|ArgumentSignatures|RemoteChatSession|StreamCodec)\w*\.\w*(STREAM_CODEC|CODEC|read|write)\w*", body):
                out.append((method.split("(")[0].split()[-1], short(body)))
    last = None
    for k, v in out:
        if k == "field": print("   field:", v)
        else:
            if k != last: print(f"   [{k}]"); last = k
            print("      ", v)
