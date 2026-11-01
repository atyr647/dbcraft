# Gateway hot-path procs.  This one file is both translated by tcl-aot and sourced at run time, so the compiled bodies attach.
# Packet layouts are Minecraft Java: VarInt length, VarInt id, body; position = 3 doubles + 2 floats + flags, big-endian.

if {[info exists ::env(TCLLIBPATH_EXTRA)]} { lappend auto_path $::env(TCLLIBPATH_EXTRA) }
package require aes

# ---- (a) VarInt -------------------------------------------------------------------------------------------------
proc vi_decode_all {buf} {
    binary scan $buf cu* bytes
    set n [llength $bytes]
    set i 0
    set sum 0
    set count 0
    while {$i < $n} {
        set v 0
        set shift 0
        while {1} {
            set b [lindex $bytes $i]
            incr i
            set v [expr {$v | (($b & 0x7f) << $shift)}]
            if {($b & 0x80) == 0} break
            incr shift 7
        }
        incr sum $v
        incr count
    }
    return "count=$count sum=$sum"
}

proc vi_encode_all {vals} {
    set out {}
    foreach v $vals {
        while {$v >= 0x80} {
            lappend out [expr {($v & 0x7f) | 0x80}]
            set v [expr {$v >> 7}]
        }
        lappend out $v
    }
    return [binary format c* $out]
}

# ---- (b) frame splitting ----------------------------------------------------------------------------------------
# way 1: `binary scan` with an @offset for every byte
proc split_scan {buf} {
    set total [string length $buf]
    set pos 0
    set frames 0
    set idsum 0
    set bodybytes 0
    while {$pos < $total} {
        set len 0
        set shift 0
        while {1} {
            binary scan $buf "@${pos}cu" b
            incr pos
            set len [expr {$len | (($b & 0x7f) << $shift)}]
            if {($b & 0x80) == 0} break
            incr shift 7
        }
        set end [expr {$pos + $len}]
        set id 0
        set shift 0
        while {1} {
            binary scan $buf "@${pos}cu" b
            incr pos
            set id [expr {$id | (($b & 0x7f) << $shift)}]
            if {($b & 0x80) == 0} break
            incr shift 7
        }
        incr idsum $id
        set blen [expr {$end - $pos}]
        binary scan $buf "@${pos}a${blen}" body
        incr bodybytes [string length $body]
        set pos $end
        incr frames
    }
    return "frames=$frames idsum=$idsum bodybytes=$bodybytes"
}

# way 2: one `binary scan cu*` into a list, then manual indexing
proc split_index {buf} {
    binary scan $buf cu* bytes
    set n [llength $bytes]
    set pos 0
    set frames 0
    set idsum 0
    set bodybytes 0
    while {$pos < $n} {
        set len 0
        set shift 0
        while {1} {
            set b [lindex $bytes $pos]
            incr pos
            set len [expr {$len | (($b & 0x7f) << $shift)}]
            if {($b & 0x80) == 0} break
            incr shift 7
        }
        set end [expr {$pos + $len}]
        set id 0
        set shift 0
        while {1} {
            set b [lindex $bytes $pos]
            incr pos
            set id [expr {$id | (($b & 0x7f) << $shift)}]
            if {($b & 0x80) == 0} break
            incr shift 7
        }
        incr idsum $id
        set body [string range $buf $pos [expr {$end - 1}]]
        incr bodybytes [string length $body]
        set pos $end
        incr frames
    }
    return "frames=$frames idsum=$idsum bodybytes=$bodybytes"
}

# ---- (c) position decode ----------------------------------------------------------------------------------------
proc pos_decode_loop {payloads iters} {
    set n [llength $payloads]
    set sx 0.0
    set sflags 0
    for {set i 0} {$i < $iters} {incr i} {
        binary scan [lindex $payloads [expr {$i % $n}]] QQQRRcu x y z yaw pitch flags
        set sx [expr {$sx + $x + $z + $yaw + $pitch}]
        incr sflags $flags
    }
    return [format "sx=%.6f flags=%d" $sx $sflags]
}

# ---- (d) build outgoing frames ----------------------------------------------------------------------------------
proc vi_bin {n} {
    set out {}
    while {$n >= 0x80} {
        lappend out [expr {($n & 0x7f) | 0x80}]
        set n [expr {$n >> 7}]
    }
    lappend out $n
    return [binary format c* $out]
}

proc build_frames {iters} {
    set out ""
    for {set i 0} {$i < $iters} {incr i} {
        set body [binary format IQQQcc $i [expr {$i * 0.5}] 64.0 [expr {$i * 0.25}] [expr {$i & 255}] [expr {($i >> 3) & 255}]]
        set id [vi_bin [expr {0x2f + ($i & 3)}]]
        set len [vi_bin [expr {[string length $id] + [string length $body]}]]
        append out $len $id $body
    }
    return $out
}

# ---- (e) one coroutine per connection ---------------------------------------------------------------------------
proc conn_machine {} {
    set state 0
    set moves 0
    set chats 0
    set other 0
    set bytes 0
    set pkt [yield]
    while {1} {
        lassign $pkt id len
        if {$id < 0} {
            return "$moves $chats $other $bytes"
        }
        incr bytes $len
        switch -- $state {
            0 { set state 1 }
            1 { set state 2 }
            2 { set state 3 }
            3 {
                if {$id == 0x1c || $id == 0x1d} {
                    incr moves
                } elseif {$id == 6} {
                    incr chats
                } else {
                    incr other
                }
            }
        }
        set pkt [yield]
    }
}

proc run_conns {nconn rounds} {
    for {set c 0} {$c < $nconn} {incr c} {
        coroutine cn$c conn_machine
    }
    set kinds {28 29 6 27}
    for {set r 0} {$r < $rounds} {incr r} {
        for {set c 0} {$c < $nconn} {incr c} {
            if {$r < 3} {
                set id 0
            } else {
                set id [lindex $kinds [expr {($c + $r) & 3}]]
            }
            set len [expr {10 + (($c * 7 + $r * 13) % 40)}]
            cn$c [list $id $len]
        }
    }
    set tm 0
    set tc 0
    set to 0
    set tb 0
    for {set c 0} {$c < $nconn} {incr c} {
        lassign [cn$c [list -1 0]] m ch o b
        incr tm $m
        incr tc $ch
        incr to $o
        incr tb $b
    }
    return "moves=$tm chats=$tc other=$to bytes=$tb"
}

# ---- (f) AES-128-CFB8 on top of tcllib's pure-Tcl ECB block function ----------------------------------------------
# CFB8 needs one full AES block encryption per byte: ks = E(register)[0]; c = p ^ ks; register = register[1..] + c
proc cfb8_encrypt {key iv data} {
    binary scan $data cu* plain
    set reg $iv
    set out {}
    foreach p $plain {
        binary scan [::aes::EncryptBlock $key $reg] cu k
        set c [expr {($p ^ $k) & 255}]
        lappend out $c
        set reg [string range $reg 1 end][binary format c $c]
    }
    return [binary format c* $out]
}

# ---- sockets (sanity check of Tcl's event loop) -------------------------------------------------------------------
# Parse the complete frames at the start of buf: returns {frames bytes-consumed}
proc sock_parse {buf} {
    binary scan $buf cu* bytes
    set n [llength $bytes]
    set pos 0
    set frames 0
    set consumed 0
    while {$pos < $n} {
        set len 0
        set shift 0
        set ok 1
        while {1} {
            if {$pos >= $n} {
                set ok 0
                break
            }
            set b [lindex $bytes $pos]
            incr pos
            set len [expr {$len | (($b & 0x7f) << $shift)}]
            if {($b & 0x80) == 0} break
            incr shift 7
        }
        if {!$ok || $pos + $len > $n} break
        set pos [expr {$pos + $len}]
        incr frames
        set consumed $pos
    }
    return [list $frames $consumed]
}

proc sock_accept {chan addr port} {
    fconfigure $chan -translation binary -blocking 0 -buffering none
    set ::sbuf($chan) ""
    incr ::nconn
    fileevent $chan readable [list sock_readable $chan]
}

proc sock_readable {chan} {
    set data [read $chan 65536]
    if {[eof $chan]} {
        close $chan
        unset -nocomplain ::sbuf($chan)
        return
    }
    append ::sbuf($chan) $data
    lassign [sock_parse $::sbuf($chan)] n used
    if {$n > 0} {
        incr ::frames $n
        set ::sbuf($chan) [string range $::sbuf($chan) $used end]
        if {$::sbuf($chan) eq ""} {
            puts -nonewline $chan "\x01"
        }
    }
}
