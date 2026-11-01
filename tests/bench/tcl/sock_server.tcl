# Event-driven Tcl server: 2000 loopback clients each send batches of frames; the server parses them (sock_parse) and acks each aligned batch.
#   env: COMPILED=1  PORT  NCONN  DUR (seconds measured after all clients are connected)
if {[info exists ::env(COMPILED)]} { load {} Gw }
source [file join [file dirname [info script]] gw_procs.tcl]
set PORT [expr {[info exists ::env(PORT)] ? $::env(PORT) : 25599}]
set NC   [expr {[info exists ::env(NCONN)] ? $::env(NCONN) : 2000}]
set DUR  [expr {[info exists ::env(DUR)] ? $::env(DUR) : 10}]
set ::frames 0; set ::nconn 0; set ::started 0
proc finish {} {
    set dt [expr {([clock milliseconds] - $::t0) / 1000.0}]
    set n [expr {$::frames - $::f0}]
    puts [format "SOCKET conns=%d seconds=%.2f frames=%d frames_per_s=%.0f" $::nconn $dt $n [expr {$n / $dt}]]
    exit 0
}
proc check {} {
    if {!$::started && $::nconn >= $::NC} {
        set ::started 1; set ::t0 [clock milliseconds]; set ::f0 $::frames
        after [expr {$::DUR * 1000}] finish
    }
    after 50 check
}
socket -server sock_accept $PORT
check
after [expr {($DUR + 60) * 1000}] {puts "SOCKET timeout: only $::nconn clients connected"; exit 1}
vwait forever
