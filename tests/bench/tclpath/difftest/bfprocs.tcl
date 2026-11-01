# Procs that call `binary format`, for a differential check of "binary format is a pure builtin" (interpreter vs compiled).
proc bf1 {a b} { binary format IQc $a $b 7 }
proc bf2 {n} { set s ""; for {set i 0} {$i < $n} {incr i} { append s [binary format ccS $i [expr {$i * 3}] $i] }; return $s }
proc bf3 {n} { set t 0; for {set i 0} {$i < $n} {incr i} { set x [binary format w $i]; incr t [string length $x] }; return $t }
proc bf_err1 {} { binary format Q notanumber }
proc bf_err2 {} { binary format }
proc bf_err3 {} { binary format I }
proc bf_err4 {x} { binary format Z $x }
proc bf_wrap {x} { binary format c $x }
proc bf_list {l} { binary format c* $l }
proc bf_local {n} { set loc 5; set r [binary format c $n]; return "$loc [string length $r]" }
proc bf_caller {} { set seen 0; trace add execution ::tcl::binary::format enter [list apply {{args} {incr ::tr}}]; set ::tr 0; set r [binary format c 9]; return "$::tr [string length $r]" }
proc bf_info {} { binary format c [expr {[info level] + 1}] }
proc bf_ns {} { namespace eval ::n1 { proc f {} { binary format cc 1 2 } }; ::n1::f }
