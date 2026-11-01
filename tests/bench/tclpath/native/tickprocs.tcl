# The per-tick gateway pattern, written the two ways a Tcl gateway could: separate native calls, or one fused call.
# n connections; per connection per tick: decrypt+split the inbound bytes, encrypt one outbound blob, write it, and add the
# inbound frames to a COPY-text batch for the database (conn, packet id, hex body).

proc tk_separate {n ticks cids ins blob chan} {
    set frames 0
    for {set t 0} {$t < $ticks} {incr t} {
        set copybuf ""
        set base [expr {$t * $n}]
        for {set c 0} {$c < $n} {incr c} {
            set cid [lindex $cids $c]
            set plain [dbc::decrypt $cid [lindex $ins [expr {$base + $c}]]]
            set r [dbc::split $plain]
            foreach {id body} [lrange $r 1 end] {
                append copybuf $c "\t" $id "\t\\\\x" [binary encode hex $body] "\n"
                incr frames
            }
            puts -nonewline $chan [dbc::encrypt $cid $blob]
        }
    }
    return $frames
}

proc tk_fused {n ticks cids ins blob chan} {
    set frames 0
    for {set t 0} {$t < $ticks} {incr t} {
        set copybuf ""
        set base [expr {$t * $n}]
        for {set c 0} {$c < $n} {incr c} {
            set r [dbc::tick [lindex $cids $c] [lindex $ins [expr {$base + $c}]] $blob]
            puts -nonewline $chan [lindex $r 1]
            foreach {id body} [lrange $r 2 end] {
                append copybuf $c "\t" $id "\t\\\\x" [binary encode hex $body] "\n"
                incr frames
            }
        }
    }
    return $frames
}

# the same loop with the native work removed: Tcl-side cost of the loop, the list handling and the batch text only
proc tk_tclonly {n ticks cids ins blob chan} {
    set frames 0
    set r [list 0 $blob 28 [string range $blob 0 31] 28 [string range $blob 0 31] 28 [string range $blob 0 31] 28 [string range $blob 0 31] 28 [string range $blob 0 31]]
    for {set t 0} {$t < $ticks} {incr t} {
        set copybuf ""
        set base [expr {$t * $n}]
        for {set c 0} {$c < $n} {incr c} {
            set x [lindex $ins [expr {$base + $c}]]
            puts -nonewline $chan [lindex $r 1]
            foreach {id body} [lrange $r 2 end] {
                append copybuf $c "\t" $id "\t\\\\x" [binary encode hex $body] "\n"
                incr frames
            }
        }
    }
    return $frames
}

proc tk_nop {k} { for {set i 0} {$i < $k} {incr i} { dbc::nop } ; return $k }
proc tk_empty {k} { for {set i 0} {$i < $k} {incr i} { } ; return $k }
