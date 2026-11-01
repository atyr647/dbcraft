if {[info exists ::env(COMPILED)]} { load {} Gw }
source gw_procs.tcl
proc slurp {f} { set c [open $f rb]; set d [read $c]; close $c; return $d }
set D $::env(DATA); set chunk [slurp $D/chunk.bin]; set exp [slurp $D/aes_expected.bin]
set key [::aes::Init ecb [binary format c* {0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15}] [string repeat \0 16]]
set iv [binary format c* {16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31}]
set t0 [clock milliseconds]; set ct [cfb8_encrypt $key $iv $chunk]; set t [expr {([clock milliseconds]-$t0)/1000.0}]
puts "AES_FULL_1MiB seconds=$t kBps=[format %.1f [expr {1048576/$t/1000.0}]] ok=[expr {$ct eq $exp}]"
