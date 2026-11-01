#!/usr/bin/env python3
"""Compare the WARN/ERROR lines of two real-client logs (dbcraft vs vanilla), ignoring timestamps and counts.

usage: python3 -I tools/realclient/logdiff.py DBCRAFT_LOG VANILLA_LOG
Prints the messages only the dbcraft session has, only the vanilla session has, and how many are common.
Continuation lines (stack traces) are ignored; digits are normalised so entity ids and times do not count as differences.
"""
import re, sys


def messages(path):
    out = {}
    for line in open(path, errors="replace"):
        m = re.match(r"\[\d\d:\d\d:\d\d\] \[([^\]]+)/(WARN|ERROR)\]: (.*)", line)
        if m:
            text = re.sub(r"\d+", "N", m.group(3))[:200]
            out[(m.group(2), text)] = out.get((m.group(2), text), 0) + 1
    return out


a, b = messages(sys.argv[1]), messages(sys.argv[2])
print(f"common: {len(set(a) & set(b))}")
for title, keys in (("only in the dbcraft session", set(a) - set(b)), ("only in the vanilla session", set(b) - set(a))):
    print(f"--- {title}: {len(keys)}")
    for k in sorted(keys):
        print(f"  {k[0]} x{(a if title.endswith('session') and 'dbcraft' in title else b)[k]}: {k[1]}")
