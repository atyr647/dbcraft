#!/usr/bin/env python3
"""Print the SQL that gives a dbcraft database the operators tests/e2e/cmd_vanilla.sh gives the vanilla server: Op1 .. Op4 with permission levels 1 .. 4
(offline-mode UUIDs are derived from the name, so both servers agree).  usage: tests/e2e/cmd_ops.py | psql ...
"""
import hashlib, uuid

for i in (1, 2, 3, 4):
    n = f"Op{i}"
    h = bytearray(hashlib.md5(("OfflinePlayer:" + n).encode()).digest()); h[6] = (h[6] & 15) | 0x30; h[8] = (h[8] & 0x3F) | 0x80
    print(f"insert into mc.op (uuid, name, level) values ('{uuid.UUID(bytes=bytes(h))}', '{n}', {i}) on conflict (uuid) do update set level = excluded.level;")
