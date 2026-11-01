// Loopback echo server on Odin's core:nbio (io_uring on Linux).  usage: echo PORT SECONDS
// Prints one line after SECONDS: peak connections, bytes echoed, MB/s, number of accepted connections.
package echo

import "core:fmt"
import "core:nbio"
import "core:net"
import "core:os"
import "core:strconv"
import "core:time"

Conn :: struct {
	sock: net.TCP_Socket,
	buf:  [4096]byte,
	n:    int,
}

total_bytes: u64
open_conns, peak_conns, accepted: int
done: bool

on_accept :: proc(op: ^nbio.Operation, server: net.TCP_Socket) {
	if op.accept.err == nil {
		c := new(Conn)
		c.sock = op.accept.client
		accepted += 1
		open_conns += 1
		peak_conns = max(peak_conns, open_conns)
		nbio.recv_poly(c.sock, {c.buf[:]}, c, on_recv)
	} else {
		fmt.eprintln("accept error:", op.accept.err)
	}
	if !done {nbio.accept_poly(server, server, on_accept)}
}

close_conn :: proc(c: ^Conn) {
	nbio.close(c.sock)
	open_conns -= 1
	free(c)
}

on_recv :: proc(op: ^nbio.Operation, c: ^Conn) {
	if op.recv.err != nil || op.recv.received == 0 {
		close_conn(c)
		return
	}
	c.n = op.recv.received
	total_bytes += u64(c.n)
	nbio.send_poly(c.sock, {c.buf[:c.n]}, c, on_sent)
}

on_sent :: proc(op: ^nbio.Operation, c: ^Conn) {
	if op.send.err != nil {
		close_conn(c)
		return
	}
	nbio.recv_poly(c.sock, {c.buf[:]}, c, on_recv)
}

main :: proc() {
	port, _ := strconv.parse_int(os.args[1])
	secs, _ := strconv.parse_int(os.args[2])
	if err := nbio.acquire_thread_event_loop(); err != nil {
		fmt.eprintln("event loop unavailable:", err)
		os.exit(1)
	}
	defer nbio.release_thread_event_loop()
	server, err := nbio.listen_tcp({net.IP4_Loopback, port}, 4096)
	if err != nil {
		fmt.eprintln("listen:", err)
		os.exit(1)
	}
	nbio.accept_poly(server, server, on_accept)
	t0 := time.tick_now()
	started := false
	t_start: time.Tick
	for {
		if e := nbio.tick(10 * time.Millisecond); e != nil {
			fmt.eprintln("tick:", e)
			break
		}
		if !started && accepted > 0 {started = true; t_start = time.tick_now(); total_bytes = 0}
		if started && time.duration_seconds(time.tick_diff(t_start, time.tick_now())) >= f64(secs) {break}
		if !started && time.duration_seconds(time.tick_diff(t0, time.tick_now())) > 60 {break}
	}
	done = true
	el := time.duration_seconds(time.tick_diff(t_start, time.tick_now()))
	fmt.printfln("ECHO peak_conns=%d accepted=%d bytes=%d seconds=%.2f MB/s=%.1f frames(31B)/s=%.0f", peak_conns, accepted, total_bytes, el, f64(total_bytes) / el / 1e6, f64(total_bytes) / 31 / el)
}
