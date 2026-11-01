// Odin port of the Rust/Tcl gateway hot-path benchmarks (tests/bench/tcl/rust/src/main.rs).
// Same inputs (../tcl/data), same logic, same RESULT lines.  Usage: gwbench DATA_DIR   (env REPS, default 5)
package gwbench

import "base:intrinsics"
import "core:c"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:simd/x86"
import "core:strconv"
import "core:time"
import "vendor:zlib"

foreign import libcrypto "system:crypto"
foreign libcrypto {
	EVP_CIPHER_CTX_new :: proc() -> rawptr ---
	EVP_CIPHER_CTX_free :: proc(ctx: rawptr) ---
	EVP_aes_128_cfb8 :: proc() -> rawptr ---
	EVP_EncryptInit_ex :: proc(ctx, cipher, engine: rawptr, key, iv: [^]u8) -> c.int ---
	EVP_DecryptInit_ex :: proc(ctx, cipher, engine: rawptr, key, iv: [^]u8) -> c.int ---
	EVP_EncryptUpdate :: proc(ctx: rawptr, out: [^]u8, outl: ^c.int, in_: [^]u8, inl: c.int) -> c.int ---
	EVP_DecryptUpdate :: proc(ctx: rawptr, out: [^]u8, outl: ^c.int, in_: [^]u8, inl: c.int) -> c.int ---
}

sink: u64 // written with volatile_store so work is not optimised away

// ---- (a) VarInt
vi_decode_all :: proc(buf: []u8) -> (count, sum: u64) {
	i := 0
	for i < len(buf) {
		v: u64
		shift: u32
		for {
			b := buf[i]
			i += 1
			v |= u64(b & 0x7f) << shift
			if b & 0x80 == 0 {break}
			shift += 7
		}
		sum += v
		count += 1
	}
	return
}

vi_encode_all :: proc(vals: []u32) -> [dynamic]u8 {
	out := make([dynamic]u8, 0, len(vals) * 2)
	for v0 in vals {
		v := v0
		for v >= 0x80 {
			append(&out, u8((v & 0x7f) | 0x80))
			v >>= 7
		}
		append(&out, u8(v))
	}
	return out
}

// ---- (b) frame splitting
read_vi :: #force_inline proc(buf: []u8, pos: ^int) -> u64 {
	v: u64
	shift: u32
	for {
		b := buf[pos^]
		pos^ += 1
		v |= u64(b & 0x7f) << shift
		if b & 0x80 == 0 {return v}
		shift += 7
	}
}

split_frames :: proc(buf: []u8) -> (frames, idsum, bodybytes: u64) {
	pos := 0
	for pos < len(buf) {
		n := int(read_vi(buf, &pos))
		end := pos + n
		idsum += read_vi(buf, &pos)
		body := make([]u8, end - pos) // copy the body out like the Tcl and Rust versions do
		copy(body, buf[pos:end])
		bodybytes += u64(len(body))
		if len(body) > 0 {intrinsics.volatile_store(&sink, u64(body[0]))}
		delete(body)
		pos = end
		frames += 1
	}
	return
}

// same, but bodies come from an arena that is reset every 1024 frames (the idiomatic Odin way)
split_frames_arena :: proc(buf: []u8, backing: []u8) -> (frames, idsum, bodybytes: u64) {
	arena: mem.Arena
	mem.arena_init(&arena, backing)
	alloc := mem.arena_allocator(&arena)
	pos := 0
	for pos < len(buf) {
		n := int(read_vi(buf, &pos))
		end := pos + n
		idsum += read_vi(buf, &pos)
		body := make([]u8, end - pos, alloc)
		copy(body, buf[pos:end])
		bodybytes += u64(len(body))
		if len(body) > 0 {intrinsics.volatile_store(&sink, u64(body[0]))}
		pos = end
		frames += 1
		if frames & 1023 == 0 {free_all(alloc)}
	}
	return
}

// ---- (c) position decode: 3 big-endian doubles, 2 big-endian floats, 1 flag byte (33 bytes)
ld_f64be :: #force_inline proc(p: [^]u8) -> f64 {
	return transmute(f64)intrinsics.byte_swap(intrinsics.unaligned_load((^u64)(p)))
}
ld_f32be :: #force_inline proc(p: [^]u8) -> f32 {
	return transmute(f32)intrinsics.byte_swap(intrinsics.unaligned_load((^u32)(p)))
}

pos_decode_loop :: proc(payloads: []u8, iters: int) -> (sx: f64, sflags: u64) {
	np := len(payloads) / 33
	for i in 0 ..< iters {
		p := raw_data(payloads[(i % np) * 33:])
		x := ld_f64be(p)
		z := ld_f64be(p[16:])
		yaw := f64(ld_f32be(p[24:]))
		pitch := f64(ld_f32be(p[28:]))
		sx = sx + x + z + yaw + pitch
		sflags += u64(p[32])
	}
	return
}

// ---- (d) build frames
vi_push :: proc(out: ^[dynamic]u8, n0: u32) {
	n := n0
	for n >= 0x80 {
		append(out, u8((n & 0x7f) | 0x80))
		n >>= 7
	}
	append(out, u8(n))
}

st_be32 :: #force_inline proc(p: [^]u8, v: u32) {
	intrinsics.unaligned_store((^u32)(p), intrinsics.byte_swap(v))
}
st_f64be :: #force_inline proc(p: [^]u8, v: f64) {
	intrinsics.unaligned_store((^u64)(p), intrinsics.byte_swap(transmute(u64)v))
}

build_frames :: proc(iters: u32) -> [dynamic]u8 {
	out := make([dynamic]u8)
	for i in 0 ..< iters {
		body: [30]u8
		b := raw_data(body[:])
		st_be32(b, i)
		st_f64be(b[4:], f64(i) * 0.5)
		st_f64be(b[12:], 64.0)
		st_f64be(b[20:], f64(i) * 0.25)
		body[28] = u8(i & 255)
		body[29] = u8((i >> 3) & 255)
		id: [dynamic]u8
		id.allocator = context.temp_allocator
		vi_push(&id, 0x2f + (i & 3))
		vi_push(&out, u32(len(id) + len(body)))
		append(&out, ..id[:])
		append(&out, ..body[:])
		free_all(context.temp_allocator)
	}
	return out
}

// ---- (e) 2000 connection state machines
Conn :: struct {
	state:                     u8,
	moves, chats, other, bytes: u64,
}

run_conns :: proc(nconn, rounds: int) -> (moves, chats, other, bytes: u64) {
	conns := make([]Conn, nconn)
	defer delete(conns)
	kinds := [4]u32{28, 29, 6, 27}
	for r in 0 ..< rounds {
		for c in 0 ..< nconn {
			id: u32 = 0 if r < 3 else kinds[(c + r) & 3]
			ln := 10 + ((c * 7 + r * 13) % 40)
			cn := &conns[c]
			cn.bytes += u64(ln)
			switch cn.state {
			case 0: cn.state = 1
			case 1: cn.state = 2
			case 2: cn.state = 3
			case:
				if id == 0x1c || id == 0x1d {cn.moves += 1} else if id == 6 {cn.chats += 1} else {cn.other += 1}
			}
		}
	}
	for cn in conns {
		moves += cn.moves
		chats += cn.chats
		other += cn.other
		bytes += cn.bytes
	}
	return
}

// ---- (f) AES-128-CFB8: OpenSSL EVP through FFI, and hand-written AES-NI with Odin's own intrinsics
RCON := [10]u8{1, 2, 4, 8, 16, 32, 64, 128, 0x1b, 0x36}
gmul :: proc(a0, b0: u8) -> u8 {
	a, b, p := a0, b0, u8(0)
	for _ in 0 ..< 8 {
		if b & 1 != 0 {p ~= a}
		hi := a & 0x80
		a <<= 1
		if hi != 0 {a ~= 0x1b}
		b >>= 1
	}
	return p
}
make_sbox :: proc() -> (sbox: [256]u8) {
	for xi in 0 ..< 256 {
		x := u8(xi)
		inv: u8 = 0
		if x != 0 {
			for y in 1 ..= 255 {
				if gmul(x, u8(y)) == 1 {inv = u8(y); break}
			}
		}
		s, r := inv, inv
		for _ in 0 ..< 4 {
			r = (r << 1) | (r >> 7)
			s ~= r
		}
		sbox[xi] = s ~ 0x63
	}
	return
}
expand_key :: proc(key: ^[16]u8, sbox: ^[256]u8) -> (w: [176]u8) {
	copy(w[:16], key[:])
	for i in 4 ..< 44 {
		t := [4]u8{w[4 * i - 4], w[4 * i - 3], w[4 * i - 2], w[4 * i - 1]}
		if i % 4 == 0 {
			t = {sbox[t[1]] ~ RCON[i / 4 - 1], sbox[t[2]], sbox[t[3]], sbox[t[0]]}
		}
		for j in 0 ..< 4 {w[4 * i + j] = w[4 * (i - 4) + j] ~ t[j]}
	}
	return
}

aes_evp :: proc(data, out: []u8, key, iv: ^[16]u8, encrypt: bool) {
	ctx := EVP_CIPHER_CTX_new()
	outl: c.int
	if encrypt {
		EVP_EncryptInit_ex(ctx, EVP_aes_128_cfb8(), nil, &key[0], &iv[0])
		EVP_EncryptUpdate(ctx, raw_data(out), &outl, raw_data(data), c.int(len(data)))
	} else {
		EVP_DecryptInit_ex(ctx, EVP_aes_128_cfb8(), nil, &key[0], &iv[0])
		EVP_DecryptUpdate(ctx, raw_data(out), &outl, raw_data(data), c.int(len(data)))
	}
	EVP_CIPHER_CTX_free(ctx)
}

@(enable_target_feature = "aes,sse2")
aes_block0 :: #force_inline proc(k: ^[11]x86.__m128i, x: x86.__m128i) -> u8 {
	b := x86._mm_xor_si128(x, k[0])
	for r in 1 ..< 10 {b = x86._mm_aesenc_si128(b, k[r])}
	b = x86._mm_aesenclast_si128(b, k[10])
	return u8(x86._mm_cvtsi128_si32(b))
}

// window trick: the register at step i is (iv ++ ciphertext)[i..i+16]
@(enable_target_feature = "aes,sse2")
cfb8_encrypt_ni :: proc(rk: ^[176]u8, iv: ^[16]u8, data, win: []u8) {
	k: [11]x86.__m128i
	for i in 0 ..< 11 {k[i] = x86._mm_loadu_si128((^x86.__m128i)(&rk[16 * i]))}
	copy(win[:16], iv[:])
	for p, i in data {
		ks := aes_block0(&k, x86._mm_loadu_si128((^x86.__m128i)(&win[i])))
		win[16 + i] = p ~ ks
	}
}

@(enable_target_feature = "aes,sse2")
cfb8_decrypt_ni :: proc(rk: ^[176]u8, iv: ^[16]u8, data, win, out: []u8) {
	k: [11]x86.__m128i
	for i in 0 ..< 11 {k[i] = x86._mm_loadu_si128((^x86.__m128i)(&rk[16 * i]))}
	copy(win[:16], iv[:])
	copy(win[16:], data)
	i := 0
	for i + 4 <= len(data) { // ciphertext is known up front: four blocks in flight
		s0 := aes_block0(&k, x86._mm_loadu_si128((^x86.__m128i)(&win[i])))
		s1 := aes_block0(&k, x86._mm_loadu_si128((^x86.__m128i)(&win[i + 1])))
		s2 := aes_block0(&k, x86._mm_loadu_si128((^x86.__m128i)(&win[i + 2])))
		s3 := aes_block0(&k, x86._mm_loadu_si128((^x86.__m128i)(&win[i + 3])))
		out[i] = data[i] ~ s0
		out[i + 1] = data[i + 1] ~ s1
		out[i + 2] = data[i + 2] ~ s2
		out[i + 3] = data[i + 3] ~ s3
		i += 4
	}
	for ; i < len(data); i += 1 {
		out[i] = data[i] ~ aes_block0(&k, x86._mm_loadu_si128((^x86.__m128i)(&win[i])))
	}
}

// ---- harness
best_ns :: proc(best: ^f64, t0: time.Tick) {
	d := time.duration_seconds(time.tick_diff(t0, time.tick_now()))
	if d < best^ {best^ = d}
}
report :: proc(name: string, best: f64, units, bytes: u64) {
	fmt.printfln("BENCH %s %.9f %d %d", name, best, units, bytes)
}

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: gwbench DATA_DIR")
		os.exit(2)
	}
	dir := os.args[1]
	reps := 5
	if s, ok := os.lookup_env("REPS", context.temp_allocator); ok {
		if n, ok2 := strconv.parse_int(s); ok2 {reps = n}
	}
	rd :: proc(dir, f: string) -> []u8 {
		path := fmt.tprintf("%s/%s", dir, f)
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil {
			fmt.eprintfln("cannot read %s: %v", path, err)
			os.exit(2)
		}
		return data
	}
	varints := rd(dir, "varints.bin")
	valsb := rd(dir, "vals.bin")
	vals := mem.slice_data_cast([]u32, valsb)
	frames := rd(dir, "frames.bin")
	posbin := rd(dir, "pos.bin")
	chunk := rd(dir, "chunk.bin")
	expected_aes := rd(dir, "aes_expected.bin")
	frames_out := rd(dir, "frames_out.bin")
	BIG :: 1e30

	{
		best := f64(BIG)
		c, s: u64
		for _ in 0 ..< reps {
			t0 := time.tick_now()
			c, s = vi_decode_all(varints)
			best_ns(&best, t0)
		}
		report("vi_decode", best, 1_000_000, u64(len(varints)))
		fmt.printfln("RESULT vi_decode count=%d sum=%d", c, s)
	}
	{
		best := f64(BIG)
		ok := false
		n := 0
		for _ in 0 ..< reps {
			t0 := time.tick_now()
			enc := vi_encode_all(vals)
			best_ns(&best, t0)
			n = len(enc)
			ok = mem.compare(enc[:], varints) == 0
			delete(enc)
		}
		report("vi_encode", best, 1_000_000, u64(len(varints)))
		fmt.printfln("RESULT vi_encode len=%d ok=%d", n, int(ok))
	}
	for name in ([]string{"split_scan", "split_index"}) {
		best := f64(BIG)
		f, i, b: u64
		for _ in 0 ..< reps {
			t0 := time.tick_now()
			f, i, b = split_frames(frames)
			best_ns(&best, t0)
		}
		report(name, best, 200_000, u64(len(frames)))
		fmt.printfln("RESULT %s frames=%d idsum=%d bodybytes=%d", name, f, i, b)
	}
	{
		backing := make([]u8, 4 << 20)
		best := f64(BIG)
		f, i, b: u64
		for _ in 0 ..< reps {
			t0 := time.tick_now()
			f, i, b = split_frames_arena(frames, backing)
			best_ns(&best, t0)
		}
		report("split_arena", best, 200_000, u64(len(frames)))
		fmt.printfln("RESULT split_arena frames=%d idsum=%d bodybytes=%d", f, i, b)
	}
	{
		best := f64(BIG)
		sx: f64
		sf: u64
		for _ in 0 ..< reps {
			t0 := time.tick_now()
			sx, sf = pos_decode_loop(posbin, 200_000)
			best_ns(&best, t0)
		}
		report("pos_decode", best, 200_000, 200_000 * 33)
		fmt.printfln("RESULT pos_decode sx=%.6f flags=%d", sx, sf)
	}
	{
		best := f64(BIG)
		ok := false
		n := 0
		for _ in 0 ..< reps {
			t0 := time.tick_now()
			fo := build_frames(200_000)
			best_ns(&best, t0)
			n = len(fo)
			ok = mem.compare(fo[:], frames_out) == 0
			delete(fo)
		}
		report("build_frames", best, 200_000, 6_400_000)
		fmt.printfln("RESULT build_frames len=%d ok=%d", n, int(ok))
	}
	{
		best := f64(BIG)
		m, ch, o, b: u64
		for _ in 0 ..< reps {
			t0 := time.tick_now()
			m, ch, o, b = run_conns(2000, 100)
			best_ns(&best, t0)
		}
		report("coro", best, 200_000, 0)
		fmt.printfln("RESULT coro moves=%d chats=%d other=%d bytes=%d", m, ch, o, b)
	}

	// zlib via vendor:zlib (bindings to the system libz), level 6
	{
		bound := int(zlib.compressBound(zlib.uLong(len(chunk))))
		zbuf := make([]u8, bound)
		zlen: int
		best := f64(BIG)
		for _ in 0 ..< reps {
			dl := zlib.uLongf(bound)
			t0 := time.tick_now()
			rc := zlib.compress2(raw_data(zbuf), &dl, raw_data(chunk), zlib.uLong(len(chunk)), 6)
			best_ns(&best, t0)
			assert(rc == 0)
			zlen = int(dl)
		}
		report("z_compress", best, 1, u64(len(chunk)))
		back := make([]u8, len(chunk))
		best = f64(BIG)
		for _ in 0 ..< reps {
			dl := zlib.uLongf(len(back))
			t0 := time.tick_now()
			rc := zlib.uncompress(raw_data(back), &dl, raw_data(zbuf), zlib.uLong(zlen))
			best_ns(&best, t0)
			assert(rc == 0)
		}
		report("z_decompress", best, 1, u64(len(chunk)))
		fmt.printfln("RESULT z_roundtrip ok=%d", int(mem.compare(back, chunk) == 0))
		fmt.printfln("INFO z_compress clen=%d", zlen)
	}

	// AES-128-CFB8, key 00..0f, iv 10..1f
	{
		key: [16]u8
		iv: [16]u8
		for i in 0 ..< 16 {key[i] = u8(i); iv[i] = u8(16 + i)}
		sbox := make_sbox()
		rk := expand_key(&key, &sbox)
		n := u64(len(chunk))
		out := make([]u8, len(chunk))
		win := make([]u8, len(chunk) + 16)

		best := f64(BIG)
		for _ in 0 ..< reps {
			t0 := time.tick_now()
			aes_evp(chunk, out, &key, &iv, true)
			best_ns(&best, t0)
		}
		report("aes_cfb8_evp", best, n, n)
		fmt.printfln("RESULT aes_cfb8_evp len=%d ok=%d", len(out), int(mem.compare(out, expected_aes) == 0))

		best = f64(BIG)
		for _ in 0 ..< reps {
			t0 := time.tick_now()
			aes_evp(expected_aes, out, &key, &iv, false)
			best_ns(&best, t0)
		}
		report("aes_cfb8_evp_dec", best, n, n)
		fmt.printfln("RESULT aes_cfb8_evp_dec len=%d ok=%d", len(out), int(mem.compare(out, chunk) == 0))

		best = f64(BIG)
		for _ in 0 ..< reps {
			t0 := time.tick_now()
			cfb8_encrypt_ni(&rk, &iv, chunk, win)
			best_ns(&best, t0)
		}
		report("aes_cfb8", best, n, n)
		fmt.printfln("RESULT aes_cfb8 len=%d ok=%d", len(chunk), int(mem.compare(win[16:], expected_aes) == 0))

		best = f64(BIG)
		for _ in 0 ..< reps {
			t0 := time.tick_now()
			cfb8_decrypt_ni(&rk, &iv, expected_aes, win, out)
			best_ns(&best, t0)
		}
		report("aes_cfb8_dec", best, n, n)
		fmt.printfln("RESULT aes_cfb8_dec len=%d ok=%d", len(out), int(mem.compare(out, chunk) == 0))
	}
}
