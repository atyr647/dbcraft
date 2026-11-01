#!/usr/bin/env python3
"""Fill the <<FLAT>> and <<DENSE>> placeholders of docs/PERF-SCALE.md with the output of report.py (headings demoted one level).
usage: python3 tests/bench/scale/fill_doc.py        (run from the repository root; idempotent only while the placeholders exist)"""
import os, re, subprocess, sys

here = os.path.dirname(os.path.abspath(__file__))
doc = os.path.join(here, "..", "..", "..", "docs", "PERF-SCALE.md")
text = open(doc).read()


def table(series):
    out = subprocess.run([sys.executable, os.path.join(here, "report.py"), series], capture_output=True, text=True, check=True).stdout
    return re.sub(r"^(#+) ", lambda m: m.group(1) + "# ", out, flags=re.M).strip()


for key, series in (("<<FLAT>>", "flat"), ("<<DENSE>>", "dense")):
    if key in text:
        text = text.replace(key, table(series))
open(doc, "w").write(text)
print("filled:", [k for k in ("<<FLAT>>", "<<DENSE>>") if k not in text])
