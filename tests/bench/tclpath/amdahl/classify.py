#!/usr/bin/env python3
"""Group callgrind exclusive costs (startup baseline subtracted, function by function) into classes and print the Amdahl bound.
usage: classify.py OUTDIR TAG [PROC ...]"""
import re, sys, subprocess, collections
out, tag = sys.argv[1], sys.argv[2]
procs = sys.argv[3:] or ["vi_decode","split_scan","split_index","pos_decode","build_frames"]
EXEC = re.compile(r"^(TEBCresume|ExecuteExtendedBinaryMathOp|TclNRRunCallbacks|EvalObjvCore|TclNREvalObjv|TclEvalObjv|TclPtr(Set|Get)VarIdx|TclObjLookupVarEx|TclLookupSimpleVar|Tcl_ObjSetVar2|Tcl_ObjGetVar2|TclIncrObj|TclIncrObjVar2|TclGetIntFromObj|TclLookupArrayElement|TclNRInterpProc|TclNRRunCallbacks|TclStackAlloc|TclStackFree|TclCompEvalObj|TclArgumentBCEnter|TclResetCancellation|Tcl_GetCommandFromObj|TclGetCommandFromObj|Tcl_FindCommand)'?\d*$")
COMP = re.compile(r"^(G__|V__|tbc_|T__|tbc)")
ALLOC = re.compile(r"^(TclpAlloc|TclpFree|TclThreadAllocObj|TclThreadFreeObj|TclpGetAllocCache|pthread_getspecific.*|TclFreeObj|Tcl_Alloc|Tcl_Free|TclpRealloc|Tcl_DbNewObj|TclNewObj|Tcl_NewObj|malloc|free|_int_malloc|_int_free|realloc|FreeListInternalRep|TclInitLiteralTable|Tcl_NewIntObj|Tcl_NewDoubleObj|Tcl_NewStringObj|Tcl_NewByteArrayObj|TclFreeIntRep|TclInvalidateStringRep|Tcl_InvalidateStringRep|Tcl_DuplicateObj)'?\d*$")
def parse(path):
    d = collections.Counter()
    for line in open(path):
        m = re.match(r"\s*([\d,]+) \(\s*[\d.]+%\)\s+(.*)$", line)
        if not m: continue
        ir = int(m.group(1).replace(",","")); rest = m.group(2)
        mm = re.match(r"(?:\S*:)?(\S+)(?:'\d+)?(?:\.\S+)? \[(.*)\]$", rest.strip())
        if not mm: continue
        fn = re.sub(r"'\d+$","",mm.group(1)); d[fn] += ir
    return d
def annotate(cg):
    txt = cg + ".full.txt"
    with open(txt,"w") as f: subprocess.run(["callgrind_annotate","--threshold=100",cg],stdout=f,stderr=subprocess.DEVNULL)
    return txt
def cls(fn):
    if COMP.match(fn): return "compiled"
    if EXEC.match(fn): return "executor"
    if ALLOC.match(fn): return "objects"
    return "library"
def load(p, mode):
    return parse(annotate(f"{out}/cg.{tag}.{p}.{mode}"))
print(f"{'proc':12} {'mode':6} {'net Minstr':>10} {'executor':>9} {'library':>9} {'objects':>9} {'compiled':>9}")
for p in procs:
    res = {}
    for mode in ("interp","aot"):
        cur, base = load(p,mode), load("none",mode)
        net = collections.Counter({k: cur[k]-base.get(k,0) for k in cur})
        tot = collections.Counter()
        for k,v in net.items():
            if v>0: tot[cls(k)] += v
        res[mode] = tot
        T = sum(tot.values())
        print(f"{p:12} {mode:6} {T/1e6:10.1f} " + " ".join(f"{tot[c]/1e6:9.1f}" for c in ("executor","library","objects","compiled")))
    I = sum(res["interp"].values()); A = sum(res["aot"].values())
    rest = res["interp"]["library"]+res["interp"]["objects"]
    print(f"{'':12} -> measured aot speedup {I/A:5.2f}x ; perfect-compile bound (executor work -> 0, library+objects unchanged) {I/rest:5.2f}x\n")
