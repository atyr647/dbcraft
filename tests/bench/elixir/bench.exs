# Elixir/BEAM gateway hot-path benchmarks: same inputs, same RESULT lines as tests/bench/tcl (Tcl, tcl-aot, Rust).
#   DATA=tests/bench/tcl/data REPS=5 PAR=4 elixir --erl "+S 4:4" bench.exs
# Prints BENCH <name> <best_seconds> <units> <bytes> and RESULT lines (compared with data/expected.txt by summarize.py).
import Bitwise

defmodule Bench do
  # ---------- harness ----------
  def best(reps, f) do
    Enum.reduce(1..reps, {nil, nil}, fn _, {best, _} ->
      :erlang.garbage_collect()
      {t, r} = :timer.tc(f)
      {if(best == nil or t < best, do: t, else: best), r}
    end)
  end

  def report(name, units, bytes, reps, f) do
    {us, r} = best(reps, f)
    IO.puts("BENCH #{name} #{:erlang.float_to_binary(us / 1.0e6, decimals: 9)} #{units} #{bytes}")
    r
  end

  # run `n` copies of f concurrently; wall time of the slowest. units are per copy.
  def par(n, f) do
    parent = self()
    pids = for _ <- 1..n, do: spawn_link(fn -> send(parent, {:par_done, self(), f.()}) end)
    for pid <- pids do
      receive do
        {:par_done, ^pid, r} -> r
      end
    end
  end

  def report_par(name, n, units, bytes, reps, f) do
    {us, _} = best(reps, fn -> par(n, f) end)
    IO.puts("BENCH #{name} #{:erlang.float_to_binary(us / 1.0e6, decimals: 9)} #{units * n} #{bytes * n}")
  end

  # ---------- (a) VarInt decode: binary pattern matching ----------
  def vi_decode(bin), do: vd(bin, 0, 0)
  defp vd(<<>>, c, s), do: {c, s}
  defp vd(<<0::1, a::7, r::binary>>, c, s), do: vd(r, c + 1, s + a)
  defp vd(<<1::1, a::7, 0::1, b::7, r::binary>>, c, s), do: vd(r, c + 1, s + a + (b <<< 7))
  defp vd(<<1::1, a::7, 1::1, b::7, 0::1, d::7, r::binary>>, c, s), do: vd(r, c + 1, s + a + (b <<< 7) + (d <<< 14))
  defp vd(<<1::1, a::7, 1::1, b::7, 1::1, d::7, 0::1, e::7, r::binary>>, c, s),
    do: vd(r, c + 1, s + a + (b <<< 7) + (d <<< 14) + (e <<< 21))
  defp vd(<<1::1, a::7, 1::1, b::7, 1::1, d::7, 1::1, e::7, 0::1, f::7, r::binary>>, c, s),
    do: vd(r, c + 1, s + a + (b <<< 7) + (d <<< 14) + (e <<< 21) + (f <<< 28))

  # ---------- (b) VarInt encode (binary append, the optimised path) ----------
  def vi_encode_all(bin), do: ve(bin, <<>>)
  defp ve(<<>>, acc), do: acc
  defp ve(<<v::little-32, r::binary>>, acc) when v < 128, do: ve(r, <<acc::binary, v>>)
  defp ve(<<v::little-32, r::binary>>, acc) when v < 16384,
    do: ve(r, <<acc::binary, (v &&& 127) ||| 128, v >>> 7>>)
  defp ve(<<v::little-32, r::binary>>, acc) when v < 2_097_152,
    do: ve(r, <<acc::binary, (v &&& 127) ||| 128, ((v >>> 7) &&& 127) ||| 128, v >>> 14>>)
  defp ve(<<v::little-32, r::binary>>, acc), do: ve(r, <<acc::binary, vi(v)::binary>>)

  def vi(n) when n < 128, do: <<n>>
  def vi(n), do: <<(n &&& 127) ||| 128, vi(n >>> 7)::binary>>

  # ---------- (c) frame split: length varint, id varint, body ----------
  # scan: body kept as a zero-copy sub-binary (idiomatic BEAM); copy: body copied out like the Rust/Tcl versions
  def split(bin, copy?), do: sp(bin, copy?, 0, 0, 0)
  defp sp(<<>>, _c, f, i, b), do: {f, i, b}
  defp sp(<<0::1, len::7, rest::binary>>, c, f, i, b), do: sp_id(len, rest, c, f, i, b)
  defp sp(<<1::1, l0::7, 0::1, l1::7, rest::binary>>, c, f, i, b), do: sp_id(l0 + (l1 <<< 7), rest, c, f, i, b)
  defp sp(<<1::1, l0::7, 1::1, l1::7, 0::1, l2::7, rest::binary>>, c, f, i, b),
    do: sp_id(l0 + (l1 <<< 7) + (l2 <<< 14), rest, c, f, i, b)

  defp sp_id(len, <<0::1, id::7, rest::binary>>, c, f, i, b), do: sp_body(len - 1, id, rest, c, f, i, b)
  defp sp_id(len, <<1::1, a::7, 0::1, d::7, rest::binary>>, c, f, i, b), do: sp_body(len - 2, a + (d <<< 7), rest, c, f, i, b)

  defp sp_body(bl, id, rest, c, f, i, b) do
    <<body::binary-size(bl), rest2::binary>> = rest
    body = if c, do: :binary.copy(body), else: body
    sp(rest2, c, f + 1, i + id, b + byte_size(body))
  end

  # ---------- (d) position decode ----------
  def pos_loop(tup, n), do: pl(tup, 0, n, 0.0, 0)
  defp pl(_t, i, n, sx, sf) when i == n, do: {sx, sf}
  defp pl(t, i, n, sx, sf) do
    <<x::float-64, _y::float-64, z::float-64, yaw::float-32, pitch::float-32, fl::8>> = elem(t, rem(i, 1000))
    pl(t, i + 1, n, sx + x + z + yaw + pitch, sf + fl)
  end

  # ---------- (e) build outgoing frames ----------
  defp frame(i) do
    body = <<i::32, i * 0.5::float-64, 64.0::float-64, i * 0.25::float-64, i &&& 255, (i >>> 3) &&& 255>>
    pid = vi(0x2F + (i &&& 3))
    [vi(byte_size(pid) + byte_size(body)), pid, body]
  end
  def build_iodata(n), do: :erlang.iolist_to_binary(for i <- 0..(n - 1), do: frame(i))
  def build_bin(n), do: bb(0, n, <<>>)
  defp bb(i, n, acc) when i == n, do: acc
  defp bb(i, n, acc) do
    body = <<i::32, i * 0.5::float-64, 64.0::float-64, i * 0.25::float-64, i &&& 255, (i >>> 3) &&& 255>>
    pid = vi(0x2F + (i &&& 3))
    bb(i + 1, n, <<acc::binary, vi(byte_size(pid) + byte_size(body))::binary, pid::binary, body::binary>>)
  end

  # ---------- (f) 2000 connection state machines x 100 rounds ----------
  @kinds {0x1C, 0x1D, 6, 0x1B}
  defp pkt(c, r), do: {if(r < 3, do: 0, else: elem(@kinds, (c + r) &&& 3)), 10 + rem(c * 7 + r * 13, 40)}

  # process-per-connection, `feeders` processes deliver the packets (round-major inside each feeder's slice)
  def coro_procs(nconn, rounds, feeders) do
    parent = self()
    fs =
      for f <- 0..(feeders - 1) do
        spawn_link(fn ->
          cs = for c <- 0..(nconn - 1), rem(c, feeders) == f, do: c
          pids = for c <- cs, do: {c, spawn(fn -> conn(0, 0, 0, 0, 0) end)}
          for r <- 0..(rounds - 1), {c, pid} <- pids do
            {id, len} = pkt(c, r)
            send(pid, {:pkt, id, len})
          end
          me = self()
          for {_c, pid} <- pids, do: send(pid, {:done, me})
          res = for _ <- pids, do: (receive do {:res, m, ch, o, by} -> {m, ch, o, by} end)
          send(parent, {:feeder, self(), Enum.reduce(res, {0, 0, 0, 0}, fn {a, b, c, d}, {x, y, z, w} -> {x + a, y + b, z + c, w + d} end)})
        end)
      end
    for f <- fs do
      receive do {:feeder, ^f, r} -> r end
    end
    |> Enum.reduce({0, 0, 0, 0}, fn {a, b, c, d}, {x, y, z, w} -> {x + a, y + b, z + c, w + d} end)
  end

  defp conn(st, m, ch, o, by) do
    receive do
      {:pkt, id, len} ->
        cond do
          st < 3 -> conn(st + 1, m, ch, o, by + len)
          id == 0x1C or id == 0x1D -> conn(st, m + 1, ch, o, by + len)
          id == 6 -> conn(st, m, ch + 1, o, by + len)
          true -> conn(st, m, ch, o + 1, by + len)
        end
      {:done, from} -> send(from, {:res, m, ch, o, by})
    end
  end

  # one process, all connection states in a list rebuilt per round (like the Rust Vec)
  def coro_single(nconn, rounds) do
    conns = List.duplicate({0, 0, 0, 0, 0}, nconn)
    conns = Enum.reduce(0..(rounds - 1), conns, fn r, cs -> rd(cs, 0, r, []) end)
    Enum.reduce(conns, {0, 0, 0, 0}, fn {_s, m, ch, o, by}, {a, b, c, d} -> {a + m, b + ch, c + o, d + by} end)
  end
  defp rd([], _c, _r, acc), do: :lists.reverse(acc)
  defp rd([{st, m, ch, o, by} | t], c, r, acc) do
    {id, len} = pkt(c, r)
    n =
      cond do
        st < 3 -> {st + 1, m, ch, o, by + len}
        id == 0x1C or id == 0x1D -> {st, m + 1, ch, o, by + len}
        id == 6 -> {st, m, ch + 1, o, by + len}
        true -> {st, m, ch, o + 1, by + len}
      end
    rd(t, c + 1, r, [n | acc])
  end

  # ---------- (g) AES-128-CFB8 via :crypto (OpenSSL EVP) ----------
  @key <<0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15>>
  @iv <<16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31>>
  def aes(data, enc?) do
    st = :crypto.crypto_init(:aes_128_cfb8, @key, @iv, enc?)
    :crypto.crypto_update(st, data)
  end
  # stateful stream cut into `size`-byte calls, like one connection's traffic
  def aes_chunks(data, size, enc?) do
    st = :crypto.crypto_init(:aes_128_cfb8, @key, @iv, enc?)
    ac(data, size, st, 0)
  end
  defp ac(<<>>, _s, _st, n), do: n
  defp ac(bin, size, st, n) when byte_size(bin) <= size, do: n + byte_size(:crypto.crypto_update(st, bin))
  defp ac(bin, size, st, n) do
    <<h::binary-size(size), t::binary>> = bin
    ac(t, size, st, n + byte_size(:crypto.crypto_update(st, h)))
  end

  # ---------- (h) zlib level 6, zlib format ----------
  def z_compress(data) do
    z = :zlib.open()
    :ok = :zlib.deflateInit(z, 6)
    out = :erlang.iolist_to_binary(:zlib.deflate(z, data, :finish))
    :ok = :zlib.deflateEnd(z)
    :zlib.close(z)
    out
  end
  def z_decompress(c) do
    z = :zlib.open()
    :ok = :zlib.inflateInit(z)
    out = :erlang.iolist_to_binary(:zlib.inflate(z, c))
    :ok = :zlib.inflateEnd(z)
    :zlib.close(z)
    out
  end

  def hex(b), do: Base.encode16(b, case: :lower)
end

dir = System.get_env("DATA") || "tests/bench/tcl/data"
reps = String.to_integer(System.get_env("REPS") || "5")
npar = String.to_integer(System.get_env("PAR") || "4")
rd = fn f -> File.read!(Path.join(dir, f)) end
varints = rd.("varints.bin")
valsbin = rd.("vals.bin")
frames = rd.("frames.bin")
posbin = rd.("pos.bin")
chunk = rd.("chunk.bin")
expected_aes = rd.("aes_expected.bin")
frames_out = rd.("frames_out.bin")
payloads = for <<p::binary-size(33) <- posbin>>, do: p
ptup = List.to_tuple(payloads)

IO.puts("INFO otp=#{:erlang.system_info(:otp_release)} schedulers=#{:erlang.system_info(:schedulers_online)} dirty_cpu=#{:erlang.system_info(:dirty_cpu_schedulers_online)} flavor=#{:erlang.system_info(:emu_flavor)} par=#{npar}")

# ---- single-process benchmarks (best of reps) ----
{c, s} = Bench.report("vi_decode", 1_000_000, byte_size(varints), reps, fn -> Bench.vi_decode(varints) end)
IO.puts("RESULT vi_decode count=#{c} sum=#{s}")
enc = Bench.report("vi_encode", 1_000_000, byte_size(varints), reps, fn -> Bench.vi_encode_all(valsbin) end)
IO.puts("RESULT vi_encode len=#{byte_size(enc)} ok=#{if enc == varints, do: 1, else: 0}")
for {name, copy?} <- [{"split_scan", false}, {"split_index", true}] do
  {f, i, b} = Bench.report(name, 200_000, byte_size(frames), reps, fn -> Bench.split(frames, copy?) end)
  IO.puts("RESULT #{name} frames=#{f} idsum=#{i} bodybytes=#{b}")
end
{sx, sf} = Bench.report("pos_decode", 200_000, 200_000 * 33, reps, fn -> Bench.pos_loop(ptup, 200_000) end)
IO.puts("RESULT pos_decode sx=#{:erlang.float_to_binary(sx, decimals: 6)} flags=#{sf}")
fo = Bench.report("build_frames", 200_000, 6_400_000, reps, fn -> Bench.build_iodata(200_000) end)
IO.puts("RESULT build_frames len=#{byte_size(fo)} ok=#{if fo == frames_out, do: 1, else: 0}")
fb = Bench.report("build_frames_bin", 200_000, 6_400_000, reps, fn -> Bench.build_bin(200_000) end)
IO.puts("RESULT build_frames_bin len=#{byte_size(fb)} ok=#{if fb == frames_out, do: 1, else: 0}")
{m, ch, o, by} = Bench.report("coro", 200_000, 0, reps, fn -> Bench.coro_procs(2000, 100, 1) end)
IO.puts("RESULT coro moves=#{m} chats=#{ch} other=#{o} bytes=#{by}")
{m, ch, o, by} = Bench.report("coro_single", 200_000, 0, reps, fn -> Bench.coro_single(2000, 100) end)
IO.puts("RESULT coro_single moves=#{m} chats=#{ch} other=#{o} bytes=#{by}")

z = Bench.report("z_compress", 1, byte_size(chunk), reps, fn -> Bench.z_compress(chunk) end)
back = Bench.report("z_decompress", 1, byte_size(chunk), reps, fn -> Bench.z_decompress(z) end)
IO.puts("RESULT z_roundtrip ok=#{if back == chunk, do: 1, else: 0}")
IO.puts("INFO z_compress clen=#{byte_size(z)}")
c128 = binary_part(chunk, 0, 131_072)
z128 = Bench.report("z_compress_128k", 1, 131_072, reps, fn -> Bench.z_compress(c128) end)
Bench.report("z_decompress_128k", 1, 131_072, reps, fn -> Bench.z_decompress(z128) end)

n = byte_size(chunk)
ae = Bench.report("aes_cfb8", n, n, reps, fn -> Bench.aes(chunk, true) end)
IO.puts("RESULT aes_cfb8 len=#{byte_size(ae)} ok=#{if ae == expected_aes, do: 1, else: 0}")
ad = Bench.report("aes_cfb8_dec", n, n, reps, fn -> Bench.aes(expected_aes, false) end)
IO.puts("RESULT aes_cfb8_dec len=#{byte_size(ad)} ok=#{if ad == chunk, do: 1, else: 0}")
# per-connection call pattern: 1000-byte outbound blobs (encrypt), 150-byte inbound (decrypt), 64-byte frames
Bench.report("aes_enc_1000B_calls", n, n, reps, fn -> Bench.aes_chunks(chunk, 1000, true) end)
Bench.report("aes_dec_150B_calls", n, n, reps, fn -> Bench.aes_chunks(expected_aes, 150, false) end)
Bench.report("aes_enc_64B_calls", n, n, reps, fn -> Bench.aes_chunks(chunk, 64, true) end)

# ---- the same work spread over `npar` processes (aggregate throughput; speedup = this / single) ----
IO.puts("INFO parallel section: #{npar} concurrent copies")
Bench.report_par("par_vi_decode", npar, 1_000_000, byte_size(varints), reps, fn -> Bench.vi_decode(varints) end)
Bench.report_par("par_split_scan", npar, 200_000, byte_size(frames), reps, fn -> Bench.split(frames, false) end)
Bench.report_par("par_split_index", npar, 200_000, byte_size(frames), reps, fn -> Bench.split(frames, true) end)
Bench.report_par("par_pos_decode", npar, 200_000, 200_000 * 33, reps, fn -> Bench.pos_loop(ptup, 200_000) end)
Bench.report_par("par_build_frames", npar, 200_000, 6_400_000, reps, fn -> Bench.build_iodata(200_000) end)
Bench.report("par_coro", 200_000, 0, reps, fn -> Bench.coro_procs(2000, 100, npar) end)
Bench.report_par("par_aes_cfb8", npar, n, n, reps, fn -> Bench.aes(chunk, true) end)
Bench.report_par("par_aes_cfb8_dec", npar, n, n, reps, fn -> Bench.aes(expected_aes, false) end)
Bench.report_par("par_aes_enc_1000B_calls", npar, n, n, reps, fn -> Bench.aes_chunks(chunk, 1000, true) end)
Bench.report_par("par_aes_dec_150B_calls", npar, n, n, reps, fn -> Bench.aes_chunks(expected_aes, 150, false) end)
Bench.report_par("par_z_compress", npar, 1, byte_size(chunk), reps, fn -> Bench.z_compress(chunk) end)
Bench.report_par("par_z_decompress", npar, 1, byte_size(chunk), reps, fn -> Bench.z_decompress(z) end)
