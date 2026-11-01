# Driver.  Prints BENCH lines (name seconds units bytes) and RESULT lines (checked against data/expected.txt).
#   env: DATA (data dir) COMPILED=1 (load the tcl-aot module first) REPS AES_BYTES
if {[info exists ::env(COMPILED)]} { load {} Gw }
source [file join [file dirname [info script]] gw_procs.tcl]
set D $::env(DATA)
set REPS [expr {[info exists ::env(REPS)] ? $::env(REPS) : 3}]
set AESN [expr {[info exists ::env(AES_BYTES)] ? $::env(AES_BYTES) : 1048576}]
set AESREPS [expr {[info exists ::env(AES_REPS)] ? $::env(AES_REPS) : 1}]

proc slurp {f} { set c [open $f rb]; set d [read $c]; close $c; return $d }

proc bench {name units bytes reps cmd} {
    set best 1e30
    for {set k 0} {$k < $reps} {incr k} {
        set t0 [clock microseconds]
        set r [uplevel #0 $cmd]
        set t [expr {([clock microseconds] - $t0) / 1e6}]
        if {$t < $best} { set best $t }
    }
    puts "BENCH $name $best $units $bytes"
    return $r
}

set varints [slurp $D/varints.bin]
set valsbin [slurp $D/vals.bin]
binary scan $valsbin iu* vals
set frames  [slurp $D/frames.bin]
set posbin  [slurp $D/pos.bin]
set payloads {}
for {set i 0} {$i < 1000} {incr i} { lappend payloads [string range $posbin [expr {$i*33}] [expr {$i*33+32}]] }
set chunk   [slurp $D/chunk.bin]

puts "RESULT vi_decode [bench vi_decode 1000000 [string length $varints] $REPS {vi_decode_all $varints}]"
set enc [bench vi_encode 1000000 [string length $varints] $REPS {vi_encode_all $vals}]
puts "RESULT vi_encode len=[string length $enc] ok=[expr {$enc eq $varints}]"
puts "RESULT split_scan [bench split_scan 200000 [string length $frames] $REPS {split_scan $frames}]"
puts "RESULT split_index [bench split_index 200000 [string length $frames] $REPS {split_index $frames}]"
puts "RESULT pos_decode [bench pos_decode 200000 [expr {200000*33}] $REPS {pos_decode_loop $payloads 200000}]"
set fo [bench build_frames 200000 6400000 $REPS {build_frames 200000}]
puts "RESULT build_frames len=[string length $fo] ok=[expr {$fo eq [slurp $D/frames_out.bin]}]"
puts "RESULT coro [bench coro 200000 0 $REPS {run_conns 2000 100}]"

# zlib: Tcl's built-in
set z [bench z_compress 1 [string length $chunk] $REPS {zlib compress $chunk 6}]
set back [bench z_decompress 1 [string length $chunk] $REPS {zlib decompress $z}]
puts "RESULT z_roundtrip ok=[expr {$back eq $chunk}]"
puts "INFO z_compress clen=[string length $z]"

# AES-CFB8: pure-Tcl block function from tcllib, one block per byte
set key [::aes::Init ecb [binary format c* {0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15}] [string repeat \0 16]]
set iv  [binary format c* {16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31}]
set exp [string range [slurp $D/aes_expected.bin] 0 [expr {$AESN-1}]]
set ct [bench aes_cfb8 $AESN $AESN $AESREPS {cfb8_encrypt $key $iv [string range $chunk 0 [expr {$AESN-1}]]}]
puts "RESULT aes_cfb8 len=[string length $ct] ok=[expr {$ct eq $exp}]"

if {[info exists ::env(COMPILED)]} { puts [tbc::report -text] }
