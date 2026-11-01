#!/usr/bin/env python3
"""Print adacraft's golden corpus (tests/corpus/*.scenario) as tab-separated rows for `\\copy ... from program`.

usage: tools/corpus_to_tsv.py [CORPUS_DIR]      (default: $DBCRAFT_CORPUS, else the adacraft checkout)
Columns: scenario, category, initial_state, step, direction, input_hex (spaces removed), outcome, packet_id, state_after, rejection_category
Prints nothing (and exits 0) when the directory does not exist, so a test can skip with a clear message.
Format: see adacraft tests/corpus/README.md (corpus_format 1).
"""
import os, sys

d = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("DBCRAFT_CORPUS", "/home/user/atyr647/adacraft/tests/corpus")
if not os.path.isdir(d):
    sys.exit(0)
for fn in sorted(os.listdir(d)):
    if not fn.endswith(".scenario") or fn.startswith("_"):
        continue
    sc, steps, cur = {}, [], None
    for line in open(os.path.join(d, fn)):
        line = line.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if line.strip() == "step:":
            cur = {}; steps.append(cur); continue
        k, _, v = line.strip().partition(":")
        (cur if cur is not None else sc)[k.strip()] = v.strip()
    for i, s in enumerate(steps, 1):
        print("\t".join([sc.get("id", fn), sc.get("category", ""), sc.get("initial_state", ""), str(i), s.get("direction", ""),
                         s.get("input", "").replace(" ", "").lower(), s.get("outcome", ""), s.get("packet_id", ""),
                         s.get("state_after", ""), s.get("rejection_category", "")]).replace("\\", "\\\\"))
