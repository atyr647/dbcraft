# Mojang session-server call pattern against a LOCAL TLS stub (never contacts Mojang).
# The real call is: GET https://sessionserver.mojang.com/session/minecraft/hasJoined?username=<name>&serverId=<hash>[&ip=<ip>]  -> 200 + JSON profile, or 204.
# The stub answers that path with a ~1.2 KB JSON body after an optional artificial upstream delay (DELAY_MS, models Mojang's round trip).
# Client and stub run in the same VM on loopback, so numbers include BOTH ends' TLS and HTTP work.  Measures (a) :httpc, (b) a pool of persistent :ssl connections.
#   DELAY_MS=0|50 elixir --erl "+S 4:4" mojang_stub.exs
import Bitwise
dir = Path.join(__DIR__, "out"); File.mkdir_p!(dir)
ca = Path.join(dir, "stub_ca.pem"); cert = Path.join(dir, "stub_cert.pem"); key = Path.join(dir, "stub_key.pem")
unless File.exists?(ca) and File.exists?(cert) do
  # a throwaway CA plus a server certificate it signed for localhost: the client does full chain and hostname verification (a self-signed leaf is rejected by OTP as selfsigned_peer)
  File.write!(Path.join(dir, "stub_ext.cnf"), "subjectAltName=DNS:localhost\n")
  sh = fn args -> {_, 0} = System.cmd("openssl", args, stderr_to_stdout: true, cd: dir) end
  sh.(~w(req -x509 -newkey rsa:2048 -nodes -keyout stub_ca_key.pem -out stub_ca.pem -days 2 -subj /CN=dbcraft-test-ca))
  sh.(~w(req -newkey rsa:2048 -nodes -keyout stub_key.pem -out stub.csr -subj /CN=localhost))
  sh.(~w(x509 -req -in stub.csr -CA stub_ca.pem -CAkey stub_ca_key.pem -CAcreateserial -out stub_cert.pem -days 2 -extfile stub_ext.cnf))
end
delay = String.to_integer(System.get_env("DELAY_MS") || "0")
port = 25790
body = ~s({"id":"069a79f444e94726a5befca90e38aaf5","name":"Notch","properties":[{"name":"textures","value":"#{String.duplicate("QUJD", 280)}","signature":"#{String.duplicate("U0lH", 100)}"}]})
resp = ["HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\nConnection: keep-alive\r\n\r\n", body]

defmodule Stub do
  def serve(l, resp, delay) do
    {:ok, t} = :ssl.transport_accept(l)
    pid = spawn(fn -> receive do :go -> handshake(t, resp, delay) end end)
    :ssl.controlling_process(t, pid); send(pid, :go)
    serve(l, resp, delay)
  end
  defp handshake(t, resp, delay) do
    case :ssl.handshake(t, 10_000) do
      {:ok, s} -> loop(s, resp, delay, <<>>)
      _ -> :ok
    end
  end
  defp loop(s, resp, delay, buf) do
    case :ssl.recv(s, 0, 30_000) do
      {:ok, data} ->
        buf = buf <> data
        case :binary.split(buf, "\r\n\r\n") do
          [_req, rest] ->
            if delay > 0, do: Process.sleep(delay)
            :ssl.send(s, resp)
            loop(s, resp, delay, rest)
          _ -> loop(s, resp, delay, buf)
        end
      _ -> :ssl.close(s)
    end
  end
end

{:ok, _} = Application.ensure_all_started(:ssl); {:ok, _} = Application.ensure_all_started(:inets)
{:ok, l} = :ssl.listen(port, [certfile: String.to_charlist(cert), keyfile: String.to_charlist(key), reuseaddr: true, active: false, mode: :binary, backlog: 4096])
for _ <- 1..8, do: spawn_link(fn -> Stub.serve(l, resp, delay) end)

url = fn i -> String.to_charlist("https://localhost:#{port}/session/minecraft/hasJoined?username=Player#{i}&serverId=4ed1f46bbe04bc756bcb17c0c7ce3e4632f06a48") end
ssl_opts = [verify: :verify_peer, cacertfile: String.to_charlist(ca), server_name_indication: ~c"localhost"]
:httpc.set_options(max_sessions: 512, max_keep_alive_length: 100_000, keep_alive_timeout: 120_000)
mono = fn -> :erlang.monotonic_time(:microsecond) end
pct = fn l, p -> s = Enum.sort(l); Enum.at(s, min(length(s) - 1, trunc(length(s) * p))) end
hreq = fn i ->
  t0 = mono.()
  r = :httpc.request(:get, {url.(i), []}, [ssl: ssl_opts, timeout: 20_000, connect_timeout: 10_000], [body_format: :binary])
  ok = match?({:ok, {{_, 200, _}, _, b}} when byte_size(b) > 1000, r)
  {ok, mono.() - t0}
end
IO.puts("INFO stub delay=#{delay} ms, body=#{byte_size(body)} B, schedulers=#{System.schedulers_online()}")
{ok, _} = hreq.(0)  # warm: TLS handshake + code paths
nseq = if delay > 0, do: 100, else: 1000
{us, res} = :timer.tc(fn -> for i <- 1..nseq, do: hreq.(i) end)
lat = for {_, l} <- res, do: l
IO.puts("HTTPC sequential #{nseq} requests: #{Float.round(nseq / (us / 1.0e6), 1)}/s  p50=#{pct.(lat, 0.5)} us p99=#{pct.(lat, 0.99)} us  failures=#{Enum.count(res, fn {o, _} -> !o end)}")
for c <- (if delay > 0, do: [64], else: [64, 256, 1024]) do
  per = if delay > 0, do: 4, else: div(4096, c) |> max(2)
  parent = self()
  {us, res} = :timer.tc(fn ->
    pids = for w <- 1..c, do: spawn_link(fn -> send(parent, {:w, self(), for(k <- 1..per, do: hreq.(w * 1000 + k))}) end)
    Enum.flat_map(pids, fn p -> receive do {:w, ^p, r} -> r end end)
  end)
  lat = for {_, l} <- res, do: l
  fails = Enum.count(res, fn {o, _} -> !o end)
  IO.puts("HTTPC concurrency #{c}: #{length(res)} logins in #{Float.round(us / 1.0e6, 2)} s = #{round(length(res) / (us / 1.0e6))}/s  p50=#{div(pct.(lat, 0.5), 1000)} ms p99=#{div(pct.(lat, 0.99), 1000)} ms failures=#{fails}")
end

# (b) pool of persistent :ssl connections, one request at a time per connection
connect = fn ->
  {:ok, s} = :ssl.connect(~c"localhost", port, [verify: :verify_peer, cacertfile: String.to_charlist(ca), server_name_indication: ~c"localhost", active: false, mode: :binary], 10_000)
  s
end
raw = fn s, i ->
  t0 = mono.()
  :ok = :ssl.send(s, "GET /session/minecraft/hasJoined?username=Player#{i}&serverId=4ed1f46bbe04bc756bcb17c0c7ce3e4632f06a48 HTTP/1.1\r\nHost: localhost\r\n\r\n")
  rd = fn rd, acc ->
    case :binary.split(acc, "\r\n\r\n") do
      [h, b] ->
        [_, len] = Regex.run(~r/Content-Length: (\d+)/, h)
        if byte_size(b) >= String.to_integer(len), do: {true, mono.() - t0}, else: (case :ssl.recv(s, 0, 20_000) do {:ok, d} -> rd.(rd, acc <> d); _ -> {false, mono.() - t0} end)
      _ -> case :ssl.recv(s, 0, 20_000) do {:ok, d} -> rd.(rd, acc <> d); _ -> {false, mono.() - t0} end
    end
  end
  rd.(rd, <<>>)
end
for c <- [64, 256, 1024] do
  per = div(8192, c) |> max(4)
  parent = self()
  t_conn = mono.()
  {us, res} = :timer.tc(fn ->
    pids = for w <- 1..c, do: spawn_link(fn -> s = connect.(); r = for(k <- 1..per, do: raw.(s, w * 1000 + k)); :ssl.close(s); send(parent, {:w, self(), r}) end)
    Enum.flat_map(pids, fn p -> receive do {:w, ^p, r} -> r end end)
  end)
  lat = for {_, l} <- res, do: l
  IO.puts("SSL-POOL #{c} connections (1 TLS handshake each, #{per} requests each): #{length(res)} logins in #{Float.round(us / 1.0e6, 2)} s incl. handshakes = #{round(length(res) / (us / 1.0e6))}/s  p50=#{div(pct.(lat, 0.5), 1000)} ms p99=#{div(pct.(lat, 0.99), 1000)} ms failures=#{Enum.count(res, fn {o, _} -> !o end)}")
end
System.halt(0)
