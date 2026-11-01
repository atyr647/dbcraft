# Run ONE gateway proc once on a fixed input (small enough for callgrind).  env: PROC, DATA (tclpath/data), COMPILED=1 loads module Gw first.
if {[info exists ::env(COMPILED)]} { load {} $::env(MODNAME) }
source $::env(PROCS)
proc slurp {f} { set c [open $f rb]; set d [read $c]; close $c; return $d }
set D $::env(DATA)
switch -- $::env(PROC) {
    none         { }
    vi_decode    { vi_decode_all [slurp $D/varints_s.bin] }
    split_scan   { split_scan [slurp $D/frames_s.bin] }
    split_index  { split_index [slurp $D/frames_s.bin] }
    pos_decode   {
        set posbin [slurp $D/pos.bin]
        set payloads {}
        for {set i 0} {$i < 1000} {incr i} { lappend payloads [string range $posbin [expr {$i*33}] [expr {$i*33+32}]] }
        pos_decode_loop $payloads 20000
    }
    build_frames { build_frames 20000 }
    vi_setup     { set v {}; for {set i 0} {$i < 100000} {incr i} { lappend v [expr {($i*2654435761) % 2000000}] } }
    vi_encode    { set v {}; for {set i 0} {$i < 100000} {incr i} { lappend v [expr {($i*2654435761) % 2000000}] }; vi_encode_all $v }
}
