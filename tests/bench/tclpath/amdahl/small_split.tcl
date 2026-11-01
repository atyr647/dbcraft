# Wall time of frame splitting at gateway-realistic buffer sizes (fits in cache): env COMPILED=1, PROCS, MODNAME
if {[info exists ::env(COMPILED)]} { load {} Gw }
source $::env(PROCS)
foreach nframes {5 30} {
    set buf [build_frames $nframes]
    set iters [expr {600000 / $nframes}]
    foreach p {split_scan split_index} {
        set best 1e30
        for {set k 0} {$k < 5} {incr k} {
            set t0 [clock microseconds]
            for {set i 0} {$i < $iters} {incr i} { $p $buf }
            set dt [expr {([clock microseconds]-$t0)/1e6}]; if {$dt < $best} { set best $dt }
        }
        puts [format "SMALL %-12s %2d frames/buffer (%4d B): %6.2f M frames/s   %6.2f us per buffer" $p $nframes [string length $buf] [expr {$iters*$nframes/$best/1e6}] [expr {$best*1e6/$iters}]]
    }
}
