#!/usr/bin/env python3
"""Write the docs of the final campaign from the raw results on disk: docs/SCOREBOARD.md (from tools/scoreboard/scoreboard.template.md plus generated tables), docs/SCOREBOARD-table.md,
docs/scoreboard-results.jsonl.txt, docs/scoreboard-results-mobs.jsonl.txt.  Rows whose cells were not (yet) re-run on the final tree show the PREVIOUS campaign's values, labelled as such
(docs/*-2026-11-04-campaign1.*), so the documents are consistent and publishable after every checkpoint.
usage: python3 tools/scoreboard/make_final_docs.py"""
import json, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import common as C
import final_report as F
import headline as H

REPO = C.REPO
DOCS = os.path.join(REPO, "docs")
NEW = os.path.join(DOCS, "final-campaign", "results.jsonl")
NEWMOBS = os.path.join(DOCS, "final-campaign", "mobs")
OLD = os.path.join(DOCS, "scoreboard-results-2026-11-04-campaign1.jsonl.txt")
OLDMOBS = os.path.join(DOCS, "scoreboard-results-mobs-2026-11-04-campaign1.jsonl.txt")


def key(r):
    return (r["scenario"].replace(" (dbcraft only)", ""), r["metric"])


def short(s):
    return s.replace(" (RCON against psql, many statements)", "")


def mobs_dir_from_old():
    d = tempfile.mkdtemp()
    with open(os.path.join(d, "vanilla.jsonl"), "w") as v, open(os.path.join(d, "dbcraft.txt"), "w") as b:
        for l in open(OLDMOBS):
            r = json.loads(l)
            if r.get("server") == "dbcraft":
                if "diag" not in r:
                    b.write(r["line"] + "\n")
            else:
                v.write(l)
    return d


def mobs_table(d, label):
    if not os.path.exists(os.path.join(d, "vanilla.jsonl")) or not os.path.exists(os.path.join(d, "dbcraft.txt")):
        return []
    out = subprocess.run([sys.executable, os.path.join(HERE, "mobs_report.py"), d, label], capture_output=True, text=True).stdout.splitlines()
    return out


def fnum(v):
    return F.fmt(v) if v is not None else "-"


def main():
    new_rows = F.build(F.load(NEW)) if os.path.exists(NEW) else []
    old_rows = F.build(F.load(OLD))
    nk = {key(r): r for r in new_rows}
    ok = {key(r): r for r in old_rows}
    # --- headline
    head = ["| Scenario | Metric | vanilla | dbcraft | ratio d/v | winner |", "|---|---|---|---|---|---|"]
    missing = []
    for lab, met, shown in H.PICK:
        hit_n = [r for r in new_rows if r["scenario"].replace(" (dbcraft only)", "").startswith(lab) and r["metric"].startswith(met)]
        hit_o = [r for r in old_rows if r["scenario"].replace(" (dbcraft only)", "").startswith(lab) and r["metric"].startswith(met)]
        if hit_n and (hit_n[0]["vmed"] is not None or hit_n[0]["dmed"] is not None):
            r = hit_n[0]
            win = r["winner"] + ((" (" + r["by"] + ")") if r["by"] and r["winner"] != "TIE" else "")
            head.append("| %s | %s | %s | %s | %s | %s |" % (short(r["scenario"]), shown, r["vanilla"], r["dbcraft"], r["ratio"], win))
        elif hit_o:
            r = hit_o[0]
            win = r["winner"] + ((" (" + r["by"] + ")") if r["by"] and r["winner"] != "TIE" else "")
            head.append("| %s | %s | *not re-run on the final tree.  Campaign 1 (older tree, other VM):* %s | *%s* | *%s* | *%s* |" % (short(r["scenario"]), shown, r["vanilla"], r["dbcraft"], r["ratio"], win))
            missing.append((short(r["scenario"]), shown))
        else:
            head.append("| %s | %s | not run | not run | | |" % (lab, shown))
    # mobs rows
    mobs_new = mobs_table(NEWMOBS, "final")
    mobs_nobody = mobs_table(NEWMOBS, "final-nobody")
    old_dir = mobs_dir_from_old()
    mobs_old = mobs_table(old_dir, "final")
    mobs_rows_new = {l.split("|")[1].strip(): [c.strip() for c in l.strip("|").split("|")] for l in mobs_new[2:] if "dbcraft only" not in l and "not run" not in l.split("|")[4]}
    mobs_rows_old = {l.split("|")[1].strip(): [c.strip() for c in l.strip("|").split("|")] for l in mobs_old[2:] if "dbcraft only" not in l}
    mobs_head = []
    mobs_chg = []
    for name in mobs_rows_old:
        if name in mobs_rows_new:
            c = mobs_rows_new[name]
            mobs_head.append("| mobs: %s | entity tick CPU per tick (ms; vanilla: Server thread) | %s | %s | %s | %s |" % (name, c[1], c[3], c[5], c[6]))
            o = mobs_rows_old[name]
            mobs_chg.append("| mobs: %s | %s -> %s | %s -> %s | %s -> %s | %s -> %s |" % (name, o[1].split(" ")[0], c[1].split(" ")[0], o[3].split(" ")[0], c[3].split(" ")[0], o[5], c[5], o[6], c[6]))
        else:
            o = mobs_rows_old[name]
            mobs_head.append("| mobs: %s | entity tick CPU per tick (ms) | *not re-run on the final tree.  Campaign 1:* %s | *%s* | *%s* | *%s* |" % (name, o[1], o[3], o[5], o[6]))
            missing.append(("mobs: " + name, "entity tick"))
    # nobody-connected rows (new only)
    for l in mobs_nobody[2:]:
        c = [x.strip() for x in l.strip("|").split("|")]
        if len(c) > 5 and "not run" not in c[3] and "dbcraft only" not in c[0]:
            mobs_head.append("| mobs: %s, **nobody connected** (dbcraft; vanilla = the same cows with the viewer away) | entity tick CPU per tick (ms) | %s | %s | %s | %s |" % (c[0], c[1], c[3], c[5], c[6]))
    headline = "\n".join(head + mobs_head)
    # --- what changed
    chg = ["| Scenario | Metric | vanilla before -> after | dbcraft before -> after | ratio d/v before -> after | winner before -> after |", "|---|---|---|---|---|---|"]
    for lab, met, shown in H.PICK:
        n = [r for r in new_rows if r["scenario"].replace(" (dbcraft only)", "").startswith(lab) and r["metric"].startswith(met) and r["dmed"] is not None]
        o = [r for r in old_rows if r["scenario"].replace(" (dbcraft only)", "").startswith(lab) and r["metric"].startswith(met) and r["dmed"] is not None]
        if n and o:
            n, o = n[0], o[0]
            wn = n["winner"] + ((" (" + n["by"] + ")") if n["by"] and n["winner"] != "TIE" else "")
            wo = o["winner"] + ((" (" + o["by"] + ")") if o["by"] and o["winner"] != "TIE" else "")
            chg.append("| %s | %s | %s -> %s | %s -> %s | %s -> %s | %s -> %s |" % (short(n["scenario"]), shown, fnum(o["vmed"]), fnum(n["vmed"]), fnum(o["dmed"]), fnum(n["dmed"]),
                                                                              o["ratio"] or "-", n["ratio"] or "-", wo, wn))
    chg += mobs_chg
    # --- generated table doc
    table_new = F.markdown(new_rows) if new_rows else "(no cell re-run yet)"
    diag = subprocess.run([sys.executable, os.path.join(HERE, "diag_report.py"), NEW], capture_output=True, text=True).stdout if os.path.exists(NEW) else ""
    cells = sum(1 for _ in open(NEW)) if os.path.exists(NEW) else 0
    with open(os.path.join(DOCS, "SCOREBOARD-table.md"), "w") as f:
        f.write("# Scoreboard: the full generated table of the final campaign\n\nGenerated by `tools/scoreboard/make_final_docs.py` from `docs/final-campaign/results.jsonl` (%d runs on the final tree).  Median over the repetitions with [min-max]; ratio = dbcraft / vanilla;\n"
                "a difference is a TIE when the two [min-max] ranges overlap.  The last column is the 1-minute load average at the start of each cell (gate 1.5).  Previous campaign: `SCOREBOARD-table-2026-11-04-campaign1.md`.\n\n"
                "## Everything except mobs\n\n%s\n\n## Mobs\n\nvanilla: CPU of the Server thread per tick; dbcraft: on-CPU ms of the entity tick (inline mode), `reset=1` harness.  Viewer connected, mobs in view (`v`) or outside his view (`n`):\n\n%s\n\n"
                "Nobody connected (dbcraft `viewers=0`):\n\n%s\n\n## Diagnosis: dbcraft with `dbcraft.dynamics = off` (not a supported configuration)\n\n%s\n\n## Not re-run on the final tree\n\n%s\n"
                % (cells, table_new, "\n".join(mobs_new) if mobs_new else "(not yet)", "\n".join(mobs_nobody) if mobs_nobody else "(not yet)", diag or "(not yet)",
                   "\n".join("- %s: %s" % m for m in missing) or "none"))
    tpl = open(os.path.join(HERE, "scoreboard.template.md")).read()
    state = ("**Campaign state at this commit: %d runs on the final tree are in the raw results; %d headline rows below were NOT re-run on the final tree and are shown in italics with the previous campaign's values (older tree, different VM).**" % (cells, len(missing))
             if missing else "**Every row of the headline table was re-run on the final tree.**")
    doc = tpl.replace("{{STATE}}", state).replace("{{HEADLINE}}", headline).replace("{{CHANGED}}", "\n".join(chg)).replace("{{DIAG}}", diag.strip() or "(not yet run)")
    open(os.path.join(DOCS, "SCOREBOARD.md"), "w").write(doc)
    shutil.copy(NEW, os.path.join(DOCS, "scoreboard-results.jsonl.txt")) if os.path.exists(NEW) else None
    with open(os.path.join(DOCS, "scoreboard-results-mobs.jsonl.txt"), "w") as f:
        if os.path.exists(os.path.join(NEWMOBS, "vanilla.jsonl")):
            f.write(open(os.path.join(NEWMOBS, "vanilla.jsonl")).read())
        if os.path.exists(os.path.join(NEWMOBS, "dbcraft.txt")):
            for l in open(os.path.join(NEWMOBS, "dbcraft.txt")):
                if l.startswith("rep "):
                    f.write(json.dumps({"server": "dbcraft", "line": l.strip()}) + "\n")
    print("docs written: %d runs, %d headline rows not re-run" % (cells, len(missing)))


main()
