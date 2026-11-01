# AES-128-CFB8 rates and correctness: OpenSSL EVP (serial) vs the AES-NI implementation (pipelined decrypt, multi-stream encrypt).
set key [binary format c* {0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15}]
set iv  [binary format c* {16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31}]
proc rnd {n seed} { set s ""; for {set i 0} {$i < $n} {incr i} { append s [format %c [expr {($seed*131 + $i*17 + ($i>>3)*5) & 255}]] }; return [encoding convertto iso8859-1 $s] }
# --- correctness: ragged lengths, several chunks per stream (state carries over), against the EVP implementation
set ok 1
foreach len {1 7 8 9 15 16 17 100 1000 3000} {
    set e [dbc::cipher create $key $iv]; set n [dbc::nicipher $key $iv]
    set d [dbc::cipher create $key $iv]; set m [dbc::nicipher $key $iv]
    for {set k 0} {$k < 3} {incr k} {
        set p [rnd $len [expr {$len+$k}]]
        set c1 [dbc::encrypt $e $p]; set c2 [dbc::nienc $n $p]
        if {$c1 ne $c2} { set ok 0; puts "MISMATCH enc len=$len chunk=$k" }
        if {[dbc::decrypt $d $c1] ne [dbc::nidec $m $c1]} { set ok 0; puts "MISMATCH dec len=$len chunk=$k" }
    }
}
# batch (ragged lanes) against serial EVP
set ids {}; set refs {}; set blobs {}
foreach len {1000 1000 999 5 1000 0 17 1000 1000 33} { lappend ids [dbc::nicipher $key $iv]; lappend refs [dbc::cipher create $key $iv]; lappend blobs [rnd $len $len] }
set out [dbc::nienc_batch $ids $blobs]
foreach r $refs b $blobs o $out { if {[dbc::encrypt $r $b] ne $o} { set ok 0; puts "MISMATCH batch" } }
puts "CHECK ni_matches_evp $ok"
# --- rates
proc rate {name script bytes reps} {
    set best 1e30
    for {set i 0} {$i < $reps} {incr i} { set t0 [clock microseconds]; uplevel #0 $script; set dt [expr {([clock microseconds]-$t0)/1e6}]; if {$dt < $best} { set best $dt } }
    puts [format "RATE %-34s %8.1f MB/s  (%.2f us per KiB)" $name [expr {$bytes/$best/1e6}] [expr {$best*1e6/($bytes/1024.0)}]]
}
set blob [rnd 1024 3]; set reps 5; set N 2000
set evp [dbc::cipher create $key $iv]; set ni [dbc::nicipher $key $iv]
rate "EVP encrypt (1 stream)"        {for {set i 0} {$i < $N} {incr i} { dbc::encrypt $evp $blob }} [expr {$N*1024}] $reps
rate "EVP decrypt (1 stream)"        {for {set i 0} {$i < $N} {incr i} { dbc::decrypt $evp $blob }} [expr {$N*1024}] $reps
rate "AES-NI encrypt (1 stream)"     {for {set i 0} {$i < $N} {incr i} { dbc::nienc $ni $blob }} [expr {$N*1024}] $reps
rate "AES-NI decrypt (pipelined x8)" {for {set i 0} {$i < $N} {incr i} { dbc::nidec $ni $blob }} [expr {$N*1024}] $reps
foreach lanes {2 4 8} {
    set ids {}; set bl {}
    for {set i 0} {$i < $lanes} {incr i} { lappend ids [dbc::nicipher $key $iv]; lappend bl $blob }
    set per [expr {$N/$lanes}]
    rate "AES-NI encrypt ($lanes streams in lockstep)" "for {set i 0} {\$i < $per} {incr i} { dbc::nienc_batch {$ids} {$bl} }" [expr {$per*$lanes*1024}] $reps
}
