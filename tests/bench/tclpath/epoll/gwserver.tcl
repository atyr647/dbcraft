# Gateway-shaped server for the socket test.  Per connection: AES-NI CFB8 cipher; readable -> decrypt, split frames, add rows to a COPY-text batch.
# Every 50 ms: encrypt one 1 KiB blob per connection (lockstep batch) and write it.  Prints one SUMMARY line.
# env: PORT NEXP DUR (seconds, after all NEXP connections exist) DBC_NOTIFIER=epoll|(select)
set PORT $::env(PORT); set NEXP $::env(NEXP); set DUR $::env(DUR)
set key [binary format c* {0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15}]
set blob [string repeat [binary format c* {1 2 3 4 5 6 7 8}] 128]
set ::chans {}; set ::ids {}; set ::frames 0; set ::copybytes 0; set ::nconn 0; set ::ticks 0; set ::tickus 0; set ::maxus 0; set ::late 0
set ::done 0; set ::started 0; set ::copybuf ""
proc cpu {} { set f [open /proc/self/stat]; set s [read $f]; close $f; set l [split [string range $s [expr {[string last ) $s]+2}] end] " "]; return [list [expr {[lindex $l 11] / 100.0}] [expr {[lindex $l 12] / 100.0}]] }
proc accept {chan addr port} {
    fconfigure $chan -translation binary -blocking 0 -buffering none -buffersize 65536
    set ::cid($chan) [dbc::nicipher $::key]; set ::rbuf($chan) ""
    lappend ::chans $chan; lappend ::ids $::cid($chan)
    fileevent $chan readable [list readable $chan]
    if {[incr ::nconn] == $::NEXP} { after 1000 start }
}
proc readable {chan} {
    set d [read $chan 65536]
    if {$d eq ""} { if {[eof $chan]} { fileevent $chan readable {}; close $chan; set ::gone($chan) 1 }; return }
    set buf $::rbuf($chan)[dbc::nidec $::cid($chan) $d]
    set r [dbc::split $buf]
    set ::rbuf($chan) [string range $buf [lindex $r 0] end]
    foreach {id body} [lrange $r 1 end] { append ::copybuf $::cid($chan) "\t" $id "\t\\\\x" [binary encode hex $body] "\n"; incr ::frames }
}
proc start {} {
    set ::started 1; set ::cpu0 [cpu]; set ::t0 [clock milliseconds]; set ::f0 $::frames
    set ::blobs [lrepeat [llength $::ids] $::blob]
    after 50 tick
}
proc tick {} {
    set t [clock microseconds]
    if {[info exists ::lastt]} { if {$t - $::lastt > 60000} { incr ::late } }
    set ::lastt $t
    set outs [dbc::nienc_batch $::ids $::blobs]
    foreach c $::chans o $outs { if {![info exists ::gone($c)]} { puts -nonewline $c $o } }
    incr ::copybytes [string length $::copybuf]; set ::copybuf ""
    set dt [expr {[clock microseconds] - $t}]
    incr ::ticks; incr ::tickus $dt; if {$dt > $::maxus} { set ::maxus $dt }
    if {[clock milliseconds] - $::t0 >= $::DUR * 1000} { set ::done 1; return }
    after [expr {max(1, 50 - $dt / 1000)}] tick
}
socket -server accept $PORT
after [expr {($::DUR + 90) * 1000}] { puts "SUMMARY timeout nconn=$::nconn"; set ::done 1 }
vwait ::done
if {$::started} {
    set wall [expr {([clock milliseconds] - $::t0) / 1000.0}]; lassign [cpu] u1 s1; lassign $::cpu0 u0 s0; set cpus [expr {$u1+$s1-$u0-$s0}]; set cu [expr {$u1-$u0}]; set cs [expr {$s1-$s0}]
    puts [format "SUMMARY conns=%d wall=%.1fs ticks=%d (%.1f TPS) frames/s=%.0f  tick_work: avg %.2f ms, max %.2f ms  late_ticks=%d  server_cpu=%.0f%% of one core (user %.0f%%, kernel %.0f%%) => %.1f us CPU per connection per 50ms tick" \
        $::nconn $wall $::ticks [expr {$::ticks / $wall}] [expr {($::frames - $::f0) / $wall}] [expr {$::tickus / 1000.0 / $::ticks}] [expr {$::maxus / 1000.0}] $::late \
        [expr {100.0 * $cpus / $wall}] [expr {100.0*$cu/$wall}] [expr {100.0*$cs/$wall}] [expr {$cpus / $wall * 50000.0 / $::nconn}]]
}
exit
