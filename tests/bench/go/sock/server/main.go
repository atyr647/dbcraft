// Loopback gateway-shaped server for GC / scheduler measurements.
// Same protocol as tests/bench/tcl/sock_server.tcl: clients send batches of 20 position frames (length varint 34 + 34 bytes); the server parses
// frames and acks each aligned batch of 20 with one byte.  To behave like a gateway and produce GC garbage it also copies every frame body
// (35 B) and builds a 1000-byte "outbound packet" per ack (about 20 KB/s per active client at the rates seen here).
// A 50 ms ticker goroutine records how late it wakes up: that is the lateness a 20 TPS tick loop would see.
//   env: PORT NCONN DUR(s) HOLD_NOSCAN_MB HOLD_PTR_MB   (GOGC / GOMAXPROCS are read by the runtime as usual)
package main

import (
	"fmt"
	"math"
	"net"
	"os"
	"runtime"
	"runtime/metrics"
	"sort"
	"strconv"
	"sync/atomic"
	"time"
)

var frames, conns atomic.Int64
var out1000 []byte // sink so the outbound buffer is really allocated

type node struct { // pointer-rich live heap, to give the GC real marking work (64 bytes)
	next *node
	a, b *node
	x, y uint64
	s    []byte
}

var holdNoscan [][]byte
var holdPtr []*node

func envInt(k string, d int) int {
	if v := os.Getenv(k); v != "" {
		n, _ := strconv.Atoi(v)
		return n
	}
	return d
}

func serve(c net.Conn) {
	defer c.Close()
	conns.Add(1)
	buf := make([]byte, 8192)
	have := 0
	nframes := 0
	for {
		n, err := c.Read(buf[have:])
		if n > 0 {
			have += n
		}
		pos := 0
		var got int64
		for pos < have {
			l := int(buf[pos]) // 1-byte length varint in this workload (34); decode properly for >127
			hdr := 1
			if l&0x80 != 0 {
				if pos+1 >= have {
					break
				}
				l = (l & 0x7f) | int(buf[pos+1])<<7
				hdr = 2
			}
			if pos+hdr+l > have {
				break
			}
			body := append([]byte(nil), buf[pos+hdr:pos+hdr+l]...) // garbage, like a real decoder that copies
			_ = body[0]
			pos += hdr + l
			got++
			nframes++
			if nframes%20 == 0 {
				out := make([]byte, 1000) // build an outbound packet
				out[0] = 1
				out1000 = out
				if _, werr := c.Write(out[:1]); werr != nil {
					return
				}
			}
		}
		copy(buf, buf[pos:have])
		have -= pos
		if got > 0 {
			frames.Add(got)
		}
		if err != nil {
			return
		}
	}
}

func hist(name string) *metrics.Float64Histogram {
	s := []metrics.Sample{{Name: name}}
	metrics.Read(s)
	if s[0].Value.Kind() != metrics.KindFloat64Histogram {
		return nil
	}
	h := s[0].Value.Float64Histogram()
	return &metrics.Float64Histogram{Counts: append([]uint64(nil), h.Counts...), Buckets: h.Buckets}
}

// quantile of the difference of two cumulative histograms; returns upper bucket bound of the bucket holding quantile q, and the max nonzero upper bound
func diffQ(a, b *metrics.Float64Histogram, q float64) (qv, max float64, total uint64) {
	if a == nil || b == nil {
		return math.NaN(), math.NaN(), 0
	}
	d := make([]uint64, len(b.Counts))
	for i := range d {
		d[i] = b.Counts[i] - a.Counts[i]
		total += d[i]
	}
	var cum uint64
	qv = math.NaN()
	for i, c := range d {
		if c == 0 {
			continue
		}
		cum += c
		up := b.Buckets[i+1]
		if math.IsInf(up, 1) {
			up = b.Buckets[i]
		}
		max = up
		if math.IsNaN(qv) && float64(cum) >= q*float64(total) {
			qv = up
		}
	}
	return
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "25700"
	}
	nc := envInt("NCONN", 5000)
	dur := time.Duration(envInt("DUR", 15)) * time.Second
	ln, err := net.Listen("tcp", "127.0.0.1:"+port)
	if err != nil {
		panic(err)
	}
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go serve(c)
		}
	}()
	// wait for all clients
	for conns.Load() < int64(nc) {
		time.Sleep(50 * time.Millisecond)
	}
	// optional live heap, allocated after connect (so the GC has to deal with it for the whole window)
	if mb := envInt("HOLD_NOSCAN_MB", 0); mb > 0 {
		for i := 0; i < mb; i++ {
			b := make([]byte, 1<<20)
			for j := 0; j < len(b); j += 4096 {
				b[j] = 1
			}
			holdNoscan = append(holdNoscan, b)
		}
	}
	if mb := envInt("HOLD_PTR_MB", 0); mb > 0 {
		n := mb * (1 << 20) / 64
		holdPtr = make([]*node, n)
		for i := range holdPtr {
			holdPtr[i] = &node{x: uint64(i)}
			if i > 0 {
				holdPtr[i].next = holdPtr[i-1]
				holdPtr[i].a = holdPtr[(uint64(i)*2654435761)%uint64(i)]
			}
		}
	}
	runtime.GC() // start the window from a settled heap
	time.Sleep(500 * time.Millisecond)

	pauses0 := hist("/sched/pauses/total/gc:seconds")
	var ms0 runtime.MemStats
	runtime.ReadMemStats(&ms0)
	f0 := frames.Load()
	t0 := time.Now()

	// 50 ms ticker lateness
	done := make(chan struct{})
	var late []float64
	tickDone := make(chan struct{})
	go func() {
		deadline := time.Now().Add(50 * time.Millisecond)
		for {
			time.Sleep(time.Until(deadline))
			now := time.Now()
			late = append(late, now.Sub(deadline).Seconds()*1000)
			deadline = deadline.Add(50 * time.Millisecond)
			if now.Sub(deadline) > 0 { // fell more than a tick behind: resync like a real loop would skip
				deadline = now.Add(50 * time.Millisecond)
			}
			select {
			case <-done:
				close(tickDone)
				return
			default:
			}
		}
	}()
	time.Sleep(dur)
	close(done)
	<-tickDone
	dt := time.Since(t0).Seconds()
	fr := frames.Load() - f0
	pauses1 := hist("/sched/pauses/total/gc:seconds")
	var ms1 runtime.MemStats
	runtime.ReadMemStats(&ms1)
	p99, pmax, pn := diffQ(pauses0, pauses1, 0.99)
	sort.Float64s(late)
	q := func(p float64) float64 { return late[int(float64(len(late)-1)*p)] }
	fmt.Printf("SOCKET conns=%d seconds=%.2f frames=%d frames_per_s=%.0f\n", conns.Load(), dt, fr, float64(fr)/dt)
	fmt.Printf("GC cycles_in_window=%d stw_pauses=%d pause_p99_ms<=%.3f pause_max_ms<=%.3f total_stw_ms=%.2f live_heap_MB=%.0f sys_MB=%.0f gogc=%s gomaxprocs=%d\n",
		ms1.NumGC-ms0.NumGC, pn, p99*1000, pmax*1000, float64(ms1.PauseTotalNs-ms0.PauseTotalNs)/1e6, float64(ms1.HeapAlloc)/1e6, float64(ms1.Sys)/1e6,
		os.Getenv("GOGC"), runtime.GOMAXPROCS(0))
	fmt.Printf("TICK50 ticks=%d lateness_ms p50=%.3f p99=%.3f p99.9=%.3f max=%.3f over5ms=%d over25ms=%d\n", len(late), q(0.5), q(0.99), q(0.999), late[len(late)-1],
		count(late, 5), count(late, 25))
	os.Exit(0)
}

func count(a []float64, th float64) int {
	n := 0
	for _, v := range a {
		if v > th {
			n++
		}
	}
	return n
}
