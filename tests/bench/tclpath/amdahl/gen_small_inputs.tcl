source /home/user/dbcraft/tests/bench/tcl/gw_procs.tcl
proc w {f d} { set c [open $f wb]; puts -nonewline $c $d; close $c }
w frames_s.bin [build_frames 20000]
set v {}; for {set i 0} {$i < 100000} {incr i} { lappend v [expr {($i*2654435761) % 2000000}] }
w varints_s.bin [vi_encode_all $v]
