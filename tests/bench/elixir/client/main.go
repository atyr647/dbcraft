// Load client for the Elixir socket tests. Stdlib only.
//   closed: each connection sends a batch of 20 frames (35 bytes each) and waits for a 1-byte ack, repeat (like tests/bench/tcl/sock_client.py)
//   open:   each connection sends -frames frames every 50 ms and never waits (the real traffic shape: ~5 packets per player per tick)
package main

import (
	"flag"
	"fmt"
	"net"
	"os"
	"sync"
	"sync/atomic"
	"time"
)

func main() {
	n := flag.Int("n", 1000, "connections")
	port := flag.Int("port", 25700, "server port")
	mode := flag.String("mode", "closed", "closed|open")
	frames := flag.Int("frames", 5, "frames per 50 ms tick in open mode")
	dur := flag.Int("dur", 20, "seconds to run after all connections are up")
	flag.Parse()

	frame := make([]byte, 35)
	frame[0], frame[1] = 34, 0x1c
	var sent, acked, up, failed int64
	stop := make(chan struct{})
	var wg sync.WaitGroup
	sem := make(chan struct{}, 256) // limit connects in flight so the accept backlog is not overrun
	for i := 0; i < *n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			var c net.Conn
			var err error
			sem <- struct{}{}
			for try := 0; try < 100; try++ {
				c, err = net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", *port))
				if err == nil {
					break
				}
				time.Sleep(50 * time.Millisecond)
			}
			<-sem
			if err != nil {
				atomic.AddInt64(&failed, 1)
				return
			}
			defer c.Close()
			c.(*net.TCPConn).SetNoDelay(true)
			atomic.AddInt64(&up, 1)
			if *mode == "closed" {
				batch := make([]byte, 0, 20*35)
				for k := 0; k < 20; k++ {
					batch = append(batch, frame...)
				}
				ack := make([]byte, 1)
				for {
					select {
					case <-stop:
						return
					default:
					}
					if _, err := c.Write(batch); err != nil {
						return
					}
					if _, err := c.Read(ack); err != nil {
						return
					}
					atomic.AddInt64(&sent, 20)
					atomic.AddInt64(&acked, 20)
				}
			}
			// open loop: offset each connection inside the tick so they do not all fire together
			time.Sleep(time.Duration(i%50) * time.Millisecond)
			buf := make([]byte, 0, *frames*35)
			for k := 0; k < *frames; k++ {
				buf = append(buf, frame...)
			}
			t := time.NewTicker(50 * time.Millisecond)
			defer t.Stop()
			for {
				select {
				case <-stop:
					return
				case <-t.C:
					if _, err := c.Write(buf); err != nil {
						return
					}
					atomic.AddInt64(&sent, int64(*frames))
				}
			}
		}(i)
	}
	for atomic.LoadInt64(&up)+atomic.LoadInt64(&failed) < int64(*n) {
		time.Sleep(100 * time.Millisecond)
	}
	fmt.Fprintf(os.Stderr, "CLIENT connected=%d failed=%d\n", atomic.LoadInt64(&up), atomic.LoadInt64(&failed))
	time.Sleep(time.Duration(*dur) * time.Second)
	close(stop)
	fmt.Printf("CLIENT mode=%s conns=%d failed=%d sent_frames=%d acked_frames=%d\n", *mode, atomic.LoadInt64(&up), atomic.LoadInt64(&failed), atomic.LoadInt64(&sent), atomic.LoadInt64(&acked))
	os.Exit(0)
}
