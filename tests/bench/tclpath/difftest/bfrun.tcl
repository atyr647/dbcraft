# prints one line per case: code | result | errorCode | errorInfo (first 3 lines)
if {[info exists ::env(COMPILED)]} { load {} Gw }
source [file join [file dirname [info script]] bfprocs.tcl]
proc show {args} {
    set rc [catch {uplevel #0 $args} res opts]
    set ei ""; set ec ""
    if {$rc} { set ei [join [lrange [split [dict get $opts -errorinfo] \n] 0 3] "\\n"]; set ec [dict get $opts -errorcode] }
    puts "[lindex $args 0] [lrange $args 1 end] | rc=$rc | [binary encode hex [string range $res 0 80]] | $ec | $ei"
}
foreach c {{bf1 7 12345678901} {bf2 20} {bf3 1000} bf_err1 bf_err2 bf_err3 {bf_err4 abc} {bf_wrap 300} {bf_wrap -1} {bf_wrap x} {bf_list {1 2 3 255 256}} {bf_list {1 x}} {bf_local 4} bf_caller bf_info bf_ns} {
    show {*}$c
}
# rename the command: the proc must follow the new definition
rename ::tcl::binary::format ::tcl::binary::format_orig
proc ::tcl::binary::format {args} { return "REPLACED" }
show bf1 1 2
show bf2 3
if {[info exists ::env(COMPILED)]} { puts "COMPILEDCOUNT [string trim [lindex [split [tbc::report -text] \n] 0]]" }
