// Go baseline for the gateway hot-path benchmarks (same inputs, same logic, same RESULT lines as the Rust and Tcl versions).
// Stdlib plus klauspost/compress (optional flate/zlib).  Usage: gobench DATA_DIR      env: REPS (default 5), AES_BYTES, GOMAXPROCS
package main

import (
	"bytes"
	"compress/zlib"
	"crypto/aes"
	"encoding/binary"
	"fmt"
	"io"
	"math"
	"os"
	"strconv"
	"time"

	kzlib "github.com/klauspost/compress/zlib"
)

var sinkI int
var sinkB []byte

func bench[T any](name string, units, nbytes uint64, reps int, f func() T) T {
	best := math.MaxFloat64
	var last T
	for i := 0; i < reps; i++ {
		t0 := time.Now()
		r := f()
		t := time.Since(t0).Seconds()
		if t < best {
			best = t
		}
		last = r
	}
	fmt.Printf("BENCH %s %.9f %d %d\n", name, best, units, nbytes)
	return last
}

// ---- (a) VarInt
func viDecodeAll(buf []byte) (uint64, uint64) {
	var sum, count uint64
	i := 0
	for i < len(buf) {
		var v uint64
		var shift uint
		for {
			b := buf[i]
			i++
			v |= uint64(b&0x7f) << shift
			if b&0x80 == 0 {
				break
			}
			shift += 7
		}
		sum += v
		count++
	}
	return count, sum
}

func viEncodeAll(vals []uint32) []byte {
	out := make([]byte, 0, len(vals)*2)
	for _, v := range vals {
		for v >= 0x80 {
			out = append(out, byte(v&0x7f|0x80))
			v >>= 7
		}
		out = append(out, byte(v))
	}
	return out
}

// ---- (b) frame split
func readVI(buf []byte, pos *int) uint64 {
	var v uint64
	var shift uint
	for {
		b := buf[*pos]
		*pos++
		v |= uint64(b&0x7f) << shift
		if b&0x80 == 0 {
			return v
		}
		shift += 7
	}
}

// copy: copy the body out like the Tcl and Rust versions do.  nocopy: a slice into the input (what idiomatic Go would do).
func splitFrames(buf []byte, copyBody bool) (frames, idsum, bodybytes uint64) {
	pos := 0
	for pos < len(buf) {
		l := int(readVI(buf, &pos))
		end := pos + l
		idsum += readVI(buf, &pos)
		var body []byte
		if copyBody {
			body = append([]byte(nil), buf[pos:end]...)
		} else {
			body = buf[pos:end]
		}
		sinkB = body
		bodybytes += uint64(len(body))
		pos = end
		frames++
	}
	return
}

// ---- (c) position decode
func posDecodeLoop(payloads [][33]byte, iters int) (float64, uint64) {
	var sx float64
	var sflags uint64
	for i := 0; i < iters; i++ {
		p := &payloads[i%len(payloads)]
		x := math.Float64frombits(binary.BigEndian.Uint64(p[0:8]))
		z := math.Float64frombits(binary.BigEndian.Uint64(p[16:24]))
		yaw := float64(math.Float32frombits(binary.BigEndian.Uint32(p[24:28])))
		pitch := float64(math.Float32frombits(binary.BigEndian.Uint32(p[28:32])))
		sx = sx + x + z + yaw + pitch
		sflags += uint64(p[32])
	}
	return sx, sflags
}

// ---- (d) build frames
func viPush(out []byte, n uint32) []byte {
	for n >= 0x80 {
		out = append(out, byte(n&0x7f|0x80))
		n >>= 7
	}
	return append(out, byte(n))
}

func buildFrames(iters uint32) []byte {
	var out []byte
	for i := uint32(0); i < iters; i++ {
		var body [30]byte
		binary.BigEndian.PutUint32(body[0:], i)
		binary.BigEndian.PutUint64(body[4:], math.Float64bits(float64(i)*0.5))
		binary.BigEndian.PutUint64(body[12:], math.Float64bits(64.0))
		binary.BigEndian.PutUint64(body[20:], math.Float64bits(float64(i)*0.25))
		body[28] = byte(i & 255)
		body[29] = byte((i >> 3) & 255)
		var idb [2]byte
		id := viPush(idb[:0], 0x2f+(i&3))
		out = viPush(out, uint32(len(id)+len(body)))
		out = append(out, id...)
		out = append(out, body[:]...)
	}
	return out
}

// ---- (e) 2000 connection state machines
type pkt struct{ id, ln int32 }
type stats struct{ moves, chats, other, bytes uint64 }

// event style: one goroutine, a slice of connection structs, a switch (what Rust does)
type conn struct {
	state int
	stats
}

func runConnsEvent(nconn, rounds int) (a, b, c, d uint64) {
	conns := make([]conn, nconn)
	kinds := [4]int32{28, 29, 6, 27}
	for r := 0; r < rounds; r++ {
		for c := 0; c < nconn; c++ {
			var id int32
			if r >= 3 {
				id = kinds[(c+r)&3]
			}
			ln := 10 + ((c*7 + r*13) % 40)
			cn := &conns[c]
			cn.bytes += uint64(ln)
			switch cn.state {
			case 0:
				cn.state = 1
			case 1:
				cn.state = 2
			case 2:
				cn.state = 3
			default:
				if id == 0x1c || id == 0x1d {
					cn.moves++
				} else if id == 6 {
					cn.chats++
				} else {
					cn.other++
				}
			}
		}
	}
	for i := range conns {
		a += conns[i].moves
		b += conns[i].chats
		c += conns[i].other
		d += conns[i].bytes
	}
	return
}

// goroutine per connection, packets delivered over a channel (the closest Go analogue of the Tcl coroutine design).
func connGoroutine(in <-chan pkt, res chan<- stats) {
	state := 0
	var s stats
	for p := range in {
		if p.id < 0 {
			break
		}
		s.bytes += uint64(p.ln)
		switch state {
		case 0:
			state = 1
		case 1:
			state = 2
		case 2:
			state = 3
		default:
			if p.id == 0x1c || p.id == 0x1d {
				s.moves++
			} else if p.id == 6 {
				s.chats++
			} else {
				s.other++
			}
		}
	}
	res <- s
}

func runConnsGoroutines(nconn, rounds, chanBuf int) (a, b, c, d uint64) {
	chans := make([]chan pkt, nconn)
	res := make(chan stats, nconn)
	for i := range chans {
		chans[i] = make(chan pkt, chanBuf)
		go connGoroutine(chans[i], res)
	}
	kinds := [4]int32{28, 29, 6, 27}
	for r := 0; r < rounds; r++ {
		for c := 0; c < nconn; c++ {
			var id int32
			if r >= 3 {
				id = kinds[(c+r)&3]
			}
			chans[c] <- pkt{id, int32(10 + ((c*7 + r*13) % 40))}
		}
	}
	for c := range chans {
		chans[c] <- pkt{-1, 0}
	}
	for range chans {
		s := <-res
		a += s.moves
		b += s.chats
		c += s.other
		d += s.bytes
	}
	return
}

// ---- (f) AES-128-CFB8 on top of crypto/aes (AES-NI assembly); std only has CFB128, so CFB8 is one Block.Encrypt per byte.
func cfb8Encrypt(key, iv, data []byte) []byte {
	blk, _ := aes.NewCipher(key)
	win := make([]byte, 16+len(data)) // register at step i is win[i:i+16]
	copy(win, iv)
	var ks [16]byte
	for i, p := range data {
		blk.Encrypt(ks[:], win[i:i+16])
		win[16+i] = p ^ ks[0]
	}
	return win[16:]
}

// Four independent connection streams interleaved byte by byte: each Encrypt call is independent of the other three streams, so the CPU can
// overlap the AES latency.  This is what a gateway with many connections can do.
func cfb8Encrypt4(key, iv []byte, data [4][]byte) [4][]byte {
	blk, _ := aes.NewCipher(key)
	var win [4][]byte
	for s := range win {
		win[s] = make([]byte, 16+len(data[s]))
		copy(win[s], iv)
	}
	var ks [4][16]byte
	for i := range data[0] {
		for s := 0; s < 4; s++ {
			blk.Encrypt(ks[s][:], win[s][i:i+16])
			win[s][16+i] = data[s][i] ^ ks[s][0]
		}
	}
	return [4][]byte{win[0][16:], win[1][16:], win[2][16:], win[3][16:]}
}

func cfb8Decrypt(key, iv, data []byte) []byte {
	blk, _ := aes.NewCipher(key)
	win := make([]byte, 16+len(data))
	copy(win, iv)
	copy(win[16:], data)
	out := make([]byte, len(data))
	var ks [16]byte
	for i, c := range data {
		blk.Encrypt(ks[:], win[i:i+16])
		out[i] = c ^ ks[0]
	}
	return out
}

// ---- zlib
type zc interface {
	compress(level int, data []byte) []byte
	decompress(z []byte, size int) []byte
}
type stdZ struct{}
type kZ struct{}

func (stdZ) compress(level int, d []byte) []byte {
	var b bytes.Buffer
	w, _ := zlib.NewWriterLevel(&b, level)
	w.Write(d)
	w.Close()
	return b.Bytes()
}
func (stdZ) decompress(z []byte, size int) []byte {
	r, _ := zlib.NewReader(bytes.NewReader(z))
	out := make([]byte, 0, size)
	buf := bytes.NewBuffer(out)
	io.Copy(buf, r)
	return buf.Bytes()
}
func (kZ) compress(level int, d []byte) []byte {
	var b bytes.Buffer
	w, _ := kzlib.NewWriterLevel(&b, level)
	w.Write(d)
	w.Close()
	return b.Bytes()
}
func (kZ) decompress(z []byte, size int) []byte {
	r, _ := kzlib.NewReader(bytes.NewReader(z))
	buf := bytes.NewBuffer(make([]byte, 0, size))
	io.Copy(buf, r)
	return buf.Bytes()
}

func main() {
	dir := os.Args[1]
	reps := 5
	if s := os.Getenv("REPS"); s != "" {
		reps, _ = strconv.Atoi(s)
	}
	aesN := 1 << 20
	if s := os.Getenv("AES_BYTES"); s != "" {
		aesN, _ = strconv.Atoi(s)
	}
	rd := func(f string) []byte {
		b, err := os.ReadFile(dir + "/" + f)
		if err != nil {
			panic(err)
		}
		return b
	}
	varints := rd("varints.bin")
	vb := rd("vals.bin")
	vals := make([]uint32, len(vb)/4)
	for i := range vals {
		vals[i] = binary.LittleEndian.Uint32(vb[i*4:])
	}
	frames := rd("frames.bin")
	pb := rd("pos.bin")
	payloads := make([][33]byte, len(pb)/33)
	for i := range payloads {
		copy(payloads[i][:], pb[i*33:])
	}
	chunk := rd("chunk.bin")

	vr := bench("vi_decode", 1_000_000, uint64(len(varints)), reps, func() [2]uint64 { a, b := viDecodeAll(varints); return [2]uint64{a, b} })
	fmt.Printf("RESULT vi_decode count=%d sum=%d\n", vr[0], vr[1])
	enc := bench("vi_encode", 1_000_000, uint64(len(varints)), reps, func() []byte { return viEncodeAll(vals) })
	ok := 0
	if bytes.Equal(enc, varints) {
		ok = 1
	}
	fmt.Printf("RESULT vi_encode len=%d ok=%d\n", len(enc), ok)
	for _, name := range []string{"split_scan", "split_index"} { // identical loop in Go; both names kept so the tables line up
		r := bench(name, 200_000, uint64(len(frames)), reps, func() [3]uint64 { a, b, c := splitFrames(frames, true); return [3]uint64{a, b, c} })
		fmt.Printf("RESULT %s frames=%d idsum=%d bodybytes=%d\n", name, r[0], r[1], r[2])
	}
	r := bench("split_nocopy", 200_000, uint64(len(frames)), reps, func() [3]uint64 { a, b, c := splitFrames(frames, false); return [3]uint64{a, b, c} })
	fmt.Printf("RESULT split_nocopy frames=%d idsum=%d bodybytes=%d\n", r[0], r[1], r[2])
	pr := bench("pos_decode", 200_000, 200_000*33, reps, func() [2]float64 { a, b := posDecodeLoop(payloads, 200_000); return [2]float64{a, float64(b)} })
	fmt.Printf("RESULT pos_decode sx=%.6f flags=%d\n", pr[0], uint64(pr[1]))
	fo := bench("build_frames", 200_000, 6_400_000, reps, func() []byte { return buildFrames(200_000) })
	ok = 0
	if bytes.Equal(fo, rd("frames_out.bin")) {
		ok = 1
	}
	fmt.Printf("RESULT build_frames len=%d ok=%d\n", len(fo), ok)
	for _, v := range []struct {
		name string
		f    func() [4]uint64
	}{
		{"coro_event", func() [4]uint64 { a, b, c, d := runConnsEvent(2000, 100); return [4]uint64{a, b, c, d} }},
		{"coro", func() [4]uint64 { a, b, c, d := runConnsGoroutines(2000, 100, 0); return [4]uint64{a, b, c, d} }}, // goroutine/unbuffered chan = Tcl coroutine analogue
		{"coro_buf", func() [4]uint64 { a, b, c, d := runConnsGoroutines(2000, 100, 128); return [4]uint64{a, b, c, d} }},
	} {
		m := bench(v.name, 200_000, 0, reps, v.f)
		fmt.Printf("RESULT %s moves=%d chats=%d other=%d bytes=%d\n", map[string]string{"coro_event": "coro", "coro": "coro", "coro_buf": "coro"}[v.name], m[0], m[1], m[2], m[3])
	}

	// zlib level 6 on the 1 MiB chunk (same as Tcl and Rust), then on 128 KiB slices
	for _, z := range []struct {
		tag string
		c   zc
	}{{"", stdZ{}}, {"_klauspost", kZ{}}} {
		var zb []byte
		bench("z_compress"+z.tag, 1, uint64(len(chunk)), reps, func() int { zb = z.c.compress(6, chunk); return len(zb) })
		var back []byte
		bench("z_decompress"+z.tag, 1, uint64(len(chunk)), reps, func() int { back = z.c.decompress(zb, len(chunk)); return len(back) })
		fmt.Printf("RESULT z_roundtrip ok=%d\n", map[bool]int{true: 1, false: 0}[bytes.Equal(back, chunk)])
		fmt.Printf("INFO z_compress%s clen=%d\n", z.tag, len(zb))
		sl := chunk[:128<<10]
		var zs []byte
		bench("z128_compress"+z.tag, 1, uint64(len(sl)), reps*2, func() int { zs = z.c.compress(6, sl); return len(zs) })
		var bs []byte
		bench("z128_decompress"+z.tag, 1, uint64(len(sl)), reps*2, func() int { bs = z.c.decompress(zs, len(sl)); return len(bs) })
		fmt.Printf("RESULT z128_roundtrip%s ok=%d clen=%d\n", z.tag, map[bool]int{true: 1, false: 0}[bytes.Equal(bs, sl)], len(zs))
	}

	key := make([]byte, 16)
	iv := make([]byte, 16)
	for i := range key {
		key[i] = byte(i)
		iv[i] = byte(16 + i)
	}
	expected := rd("aes_expected.bin")
	n := uint64(len(chunk))
	if aesN < len(chunk) {
		n = uint64(aesN)
	}
	pt, ex := chunk[:n], expected[:n]
	ct := bench("aes_cfb8", n, n, reps, func() []byte { return cfb8Encrypt(key, iv, pt) })
	fmt.Printf("RESULT aes_cfb8 len=%d ok=%d\n", len(ct), map[bool]int{true: 1, false: 0}[bytes.Equal(ct, ex)])
	dt := bench("aes_cfb8_dec", n, n, reps, func() []byte { return cfb8Decrypt(key, iv, ex) })
	q := len(pt) / 4
	var parts [4][]byte
	for k := range parts {
		parts[k] = pt[k*q : (k+1)*q]
	}
	x4 := bench("aes_cfb8_x4", n, n, reps, func() [4][]byte { return cfb8Encrypt4(key, iv, parts) })
	x4ok := 1
	for k := range parts {
		if !bytes.Equal(x4[k], cfb8Encrypt(key, iv, parts[k])) {
			x4ok = 0
		}
	}
	fmt.Printf("RESULT aes_cfb8_x4 ok=%d\n", x4ok)
	fmt.Printf("RESULT aes_cfb8_dec len=%d ok=%d\n", len(dt), map[bool]int{true: 1, false: 0}[bytes.Equal(dt, pt)])
}
