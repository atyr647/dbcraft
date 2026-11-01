// Closed-loop load generator for sock/server (same behaviour as tests/bench/tcl/sock_client.py, in Go so 20,000 clients are cheap).
//   env: PORT NCONN PACE_MS (sleep after each ack; 0 = saturated closed loop, 200 = about 100 frames/s per connection)   runs until the server closes the connections / exits
package main

import (
	"encoding/binary"
	"fmt"
	"math"
	"math/rand"
	"net"
	"os"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "25700"
	}
	n, _ := strconv.Atoi(os.Getenv("NCONN"))
	if n == 0 {
		n = 5000
	}
	frame := make([]byte, 35)
	frame[0], frame[1] = 34, 0x1C
	binary.BigEndian.PutUint64(frame[2:], math.Float64bits(1.5))
	binary.BigEndian.PutUint64(frame[10:], math.Float64bits(64))
	binary.BigEndian.PutUint64(frame[18:], math.Float64bits(-2.5))
	binary.BigEndian.PutUint32(frame[26:], math.Float32bits(90))
	frame[34] = 1
	batch := make([]byte, 0, 35*20)
	for i := 0; i < 20; i++ {
		batch = append(batch, frame...)
	}
	pace := time.Duration(0)
	if v, _ := strconv.Atoi(os.Getenv("PACE_MS")); v > 0 {
		pace = time.Duration(v) * time.Millisecond
	}
	var acked atomic.Int64
	var wg sync.WaitGroup
	sem := make(chan struct{}, 256) // ramp up connections gently (listen backlog)
	for i := 0; i < n; i++ {
		wg.Add(1)
		sem <- struct{}{}
		go func() {
			defer wg.Done()
			var c net.Conn
			var err error
			for a := 0; a < 100; a++ {
				c, err = net.Dial("tcp", "127.0.0.1:"+port)
				if err == nil {
					break
				}
				time.Sleep(50 * time.Millisecond)
			}
			<-sem
			if err != nil {
				return
			}
			defer c.Close()
			one := make([]byte, 1)
			if pace > 0 {
				time.Sleep(time.Duration(rand.Int63n(int64(pace)))) // spread the connections over the period
			}
			for {
				if _, err := c.Write(batch); err != nil {
					return
				}
				if _, err := c.Read(one); err != nil {
					return
				}
				acked.Add(20)
				if pace > 0 {
					time.Sleep(pace)
				}
			}
		}()
	}
	wg.Wait()
	fmt.Printf("client frames acked: %d\n", acked.Load())
}
