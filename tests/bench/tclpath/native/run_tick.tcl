# env: COMPILED=1 (load module Tk first), NCON, TICKS, REPS.  Prints BENCH lines: name ms_per_tick players_per_core.
if {[info exists ::env(COMPILED)]} { load {} Tk }
source [file join [file dirname [info script]] tickprocs.tcl]
set N [expr {[info exists ::env(NCON)] ? $::env(NCON) : 2000}]
set T [expr {[info exists ::env(TICKS)] ? $::env(TICKS) : 20}]
set REPS [expr {[info exists ::env(REPS)] ? $::env(REPS) : 5}]
set key [binary format c* {0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15}]
# plaintext for a client: 5 position frames of 32-byte bodies (length 33, id 0x1c) = 170 bytes
proc frames5 {seed} {
    set s ""
    for {set i 0} {$i < 5} {incr i} {
        set body ""
        for {set j 0} {$j < 32} {incr j} { append body [format %c [expr {($seed * 31 + $i * 7 + $j * 3) & 255}]] }
        append s [binary format cc 33 28] [encoding convertto iso8859-1 $body]
    }
    return $s
}
set blob [string repeat [binary format c* {1 2 3 4 5 6 7 8}] 128]   ;# 1 KiB outbound
# client side: one cipher per connection produces the ciphertext stream the server must decrypt
set clients {}; for {set c 0} {$c < $N} {incr c} { lappend clients [dbc::cipher create $key] }
set ins {}
for {set t 0} {$t < $T} {incr t} { for {set c 0} {$c < $N} {incr c} { lappend ins [dbc::encrypt [lindex $clients $c] [frames5 [expr {$t*$N+$c}]]] } }
set chan [open /dev/null wb]; fconfigure $chan -translation binary -buffering none
proc fresh {N key} { set l {}; for {set c 0} {$c < $N} {incr c} { lappend l [dbc::cipher create $key] }; return $l }
proc run {name cmd N T REPS} {
    set best 1e30
    for {set k 0} {$k < $REPS} {incr k} {
        set servers [fresh $N $::key]
        set t0 [clock microseconds]
        set f [uplevel #0 [list {*}$cmd $servers $::ins $::blob $::chan]]
        set dt [expr {([clock microseconds] - $t0) / 1e6}]
        foreach s $servers { dbc::cipher free $s }
        if {$dt < $best} { set best $dt }
    }
    set ms [expr {$best * 1000.0 / $T}]
    puts [format "BENCH %-14s %8.3f ms/tick for %d conns  => %6.0f players/core at 100%% of a 50 ms tick (frames=%d)" $name $ms $N [expr {$N * 50.0 / $ms}] $f]
}

# ---- correctness: AES-128-CFB8 against `openssl enc` output from the earlier benchmark (key 0..15, iv 16..31) and the split against known frames
set D /home/user/dbcraft/tests/bench/tcl/data
if {[file exists $D/aes_expected.bin]} {
    set f [open $D/chunk.bin rb]; set plain [read $f 65536]; close $f
    set f [open $D/aes_expected.bin rb]; set exp [read $f 65536]; close $f
    set iv [binary format c* {16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31}]
    set id [dbc::cipher create $key $iv]
    set got [dbc::encrypt $id $plain]
    set id2 [dbc::cipher create $key $iv]
    puts "CHECK aes_cfb8_encrypt_matches_openssl [expr {$got eq $exp}]  decrypt_roundtrip [expr {[dbc::decrypt $id2 $got] eq $plain}]"
}
set two [binary format cc 33 28][string repeat a 32][binary format cc 3 7]ab
lassign [dbc::split $two[binary format c 9]] used i1 b1 i2 b2 extra
puts "CHECK split consumed=$used (expect [expr {34+4}]) ids=$i1,$i2 bodylens=[string length $b1],[string length $b2]"

# ---- measurements
run tclonly   "tk_tclonly $N $T"   $N $T $REPS
run separate  "tk_separate $N $T"  $N $T $REPS
run fused     "tk_fused $N $T"     $N $T $REPS
set k 2000000
foreach {nm p} {empty-loop tk_empty nop-call tk_nop} {
    set best 1e30
    for {set r 0} {$r < $REPS} {incr r} { set t0 [clock microseconds]; $p $k; set dt [expr {([clock microseconds]-$t0)/1e6}]; if {$dt < $best} {set best $dt} }
    puts [format "BENCH %-14s %8.1f ns per iteration" $nm [expr {$best * 1e9 / $k}]]
}
if {[info exists ::env(COMPILED)]} { puts [tbc::report -text] }
