# dbc::split on the same buffers as amdahl/small_split.tcl (frames: length, id, 32-byte body... 5 and 30 frames)
proc mk {n} { set s ""; for {set i 0} {$i < $n} {incr i} { append s [binary format cc 33 28][string repeat x 32] }; return $s }
foreach nframes {5 30} {
    set buf [mk $nframes]; set iters [expr {600000 / $nframes}]; set best 1e30
    for {set k 0} {$k < 5} {incr k} {
        set t0 [clock microseconds]; for {set i 0} {$i < $iters} {incr i} { dbc::split $buf }
        set dt [expr {([clock microseconds]-$t0)/1e6}]; if {$dt < $best} { set best $dt }
    }
    puts [format "SMALL dbc::split   %2d frames/buffer (%4d B): %6.2f M frames/s   %6.2f us per buffer" $nframes [string length $buf] [expr {$iters*$nframes/$best/1e6}] [expr {$best*1e6/$iters}]]
}
