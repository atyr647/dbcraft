# BEAM socket server: one process per connection ({active, N}), frame counting, 50 ms tick-lateness probe, GC/schedule monitors.
#   env: PORT NCONN DUR GW_MODE=closed|open|pg  (not MODE: the elixir launcher script overwrites it)  TICK_PRIO=high (tick process priority)  HOLD_MB (live refc binaries in one process)  PERCONN_KB (live buffer per connection)
#        PG_PORT (default 54388) for MODE=pg
#   elixir --erl "+S 4:4 +Q 65536" sock_server.exs
mode = System.get_env("GW_MODE") || "closed"
if mode == "pg", do: Mix.install([{:postgrex, "~> 0.17"}])

defmodule Srv do
  @window 64

  def mono, do: :erlang.monotonic_time(:microsecond)
  def rss_kb do
    {:ok, s} = File.read("/proc/self/status")
    [_, kb] = Regex.run(~r/VmRSS:\s+(\d+) kB/, s)
    String.to_integer(kb)
  end

  # ---- counters ----
  def init_counters do
    :persistent_term.put(:frames, :counters.new(System.schedulers_online() + 1, [:write_concurrency]))
    :persistent_term.put(:up, :atomics.new(1, []))
    :ets.new(:conns, [:public, :named_table, :bag])
  end
  def count(n), do: :counters.add(:persistent_term.get(:frames), :erlang.system_info(:scheduler_id), n)
  def total do
    r = :persistent_term.get(:frames)
    Enum.sum(for i <- 1..(System.schedulers_online() + 1), do: :counters.get(r, i))
  end

  # ---- accept + connection processes ----
  def listen(port) do
    {:ok, l} = :gen_tcp.listen(port, [:binary, packet: :raw, active: false, reuseaddr: true, backlog: 8192, nodelay: true])
    l
  end
  def acceptor(l, mode, kb, collector) do
    case :gen_tcp.accept(l) do
      {:ok, s} ->
        id = :atomics.add_get(:persistent_term.get(:up), 1, 1)
        pid = spawn(fn -> conn_init(s, id, mode, kb, collector) end)
        :ok = :gen_tcp.controlling_process(s, pid)
        send(pid, :go)
        :ets.insert(:conns, {pid})
        acceptor(l, mode, kb, collector)
      {:error, _} -> acceptor(l, mode, kb, collector)
    end
  end
  defp conn_init(s, id, mode, kb, collector) do
    receive do :go -> :ok end
    held = if kb > 0, do: :binary.copy(<<7>>, kb * 1024), else: <<>>
    :inet.setopts(s, active: @window)
    loop(s, <<>>, 0, id, mode, collector, held)
  end
  defp loop(s, buf, since, id, mode, collector, held) do
    receive do
      {:tcp, ^s, data} ->
        bin = if buf == <<>>, do: data, else: <<buf::binary, data::binary>>
        {rest, n, bodies} = if collector, do: parse_collect(bin, 0, []), else: parse(bin, 0)
        count(n)
        if collector && n > 0, do: send(collector, {:frames, id, bodies})
        since = since + n
        since =
          if mode == "closed" and since >= 20 do
            acks = div(since, 20)
            :gen_tcp.send(s, :binary.copy(<<1>>, acks))
            since - acks * 20
          else
            since
          end
        loop(s, rest, since, id, mode, collector, held)
      {:tcp_passive, ^s} -> :inet.setopts(s, active: @window); loop(s, buf, since, id, mode, collector, held)
      {:tcp_closed, ^s} -> :ok
      {:tcp_error, ^s, _} -> :ok
    end
  end
  # frame = 1-byte length (< 128) + that many bytes
  defp parse(<<len, rest::binary>> = bin, n) do
    case rest do
      <<_body::binary-size(len), rest2::binary>> -> parse(rest2, n + 1)
      _ -> {bin, n, []}
    end
  end
  defp parse(<<>>, n), do: {<<>>, n, []}
  defp parse_collect(<<len, rest::binary>> = bin, n, acc) do
    case rest do
      <<body::binary-size(len), rest2::binary>> -> parse_collect(rest2, n + 1, [body | acc])
      _ -> {bin, n, :lists.reverse(acc)}
    end
  end
  defp parse_collect(<<>>, n, acc), do: {<<>>, n, :lists.reverse(acc)}

  # ---- 50 ms tick probe on an absolute grid: records (timestamp, lateness_us = actual - scheduled) ----
  def ticker do
    if System.get_env("TICK_PRIO") == "high", do: Process.flag(:priority, :high)
    next = mono() + 50_000
    arm(next)
    ticker_loop(next, [])
  end
  defp arm(next), do: :erlang.send_after(max(0, div(next - mono() + 999, 1000)), self(), :tick)
  defp ticker_loop(next, acc) do
    receive do
      :tick ->
        now = mono()
        nxt = next + 50_000
        arm(nxt)
        ticker_loop(nxt, [{now, now - next} | acc])
      {:get, from} -> send(from, {:ticks, acc}); ticker_loop(next, acc)
    end
  end

  # ---- holder of ~mb MiB of live data in ONE process, full-sweep GC every 200 ms ----
  #   kind "bins": 64 KiB refc binaries (off-heap); kind "heap": a list on the process heap (16 B per element), so each GC copies it all
  def holder(mb, kind) do
    data = if kind == "heap", do: :lists.seq(1, mb * 65_536), else: for(_ <- 1..(mb * 16), do: :binary.copy(<<0>>, 65_536))
    holder_loop(data)
  end
  defp holder_loop(data) do
    t = mono()
    :erlang.garbage_collect()
    gc_us = mono() - t
    if gc_us > 20_000, do: IO.puts("HOLDER full-sweep gc took #{div(gc_us, 1000)} ms")
    receive do after 200 -> holder_loop(data) end
  end

  # ---- Postgres batching collector (MODE=pg): every 50 ms one binary COPY of everything received ----
  def collector(pg) do
    if System.get_env("TICK_PRIO") == "high", do: Process.flag(:priority, :high)
    next = mono() + 50_000
    arm_flush(next)
    collector_loop(pg, [], 0, next, [])
  end
  defp arm_flush(next), do: :erlang.send_after(max(0, div(next - mono() + 999, 1000)), self(), :flush)
  defp collector_loop(pg, acc, tick, next, stats) do
    receive do
      {:frames, id, bodies} -> collector_loop(pg, [{id, bodies} | acc], tick, next, stats)
      :flush ->
        t0 = mono()
        nxt = next + 50_000
        arm_flush(nxt)
        rows =
          for {id, bodies} <- :lists.reverse(acc), b <- bodies do
            <<3::16, 8::32, tick::64, 4::32, id::32, byte_size(b)::32, b::binary>>
          end
        t1 = mono()
        header = <<"PGCOPY\n", 255, ?\r, ?\n, 0, 0::32, 0::32>>
        {:ok, _} =
          Postgrex.transaction(pg, fn c ->
            Enum.into([header, rows, <<-1::16>>], Postgrex.stream(c, "COPY net.inbox FROM STDIN WITH (FORMAT binary)", []))
          end)
        t2 = mono()
        Postgrex.query!(pg, "with c as (delete from net.inbox returning 1) select count(*) from c", [])  # stand-in for net.tick consuming the rows
        t3 = mono()
        collector_loop(pg, [], tick + 1, nxt, [{length(rows), t1 - t0, t2 - t1, t3 - t2, t3 - t0, t0 - next} | stats])
      {:get, from} -> send(from, {:stats, stats}); collector_loop(pg, acc, tick, next, stats)
    end
  end

  # ---- reporting ----
  def pct(sorted, p), do: Enum.at(sorted, min(length(sorted) - 1, trunc(length(sorted) * p)))
  def drain_monitor(acc \\ {0, 0, 0, 0}) do
    receive do
      {:monitor, _pid, :long_gc, info} ->
        {a, b, c, d} = acc
        drain_monitor({a + 1, max(b, Keyword.get(info, :timeout, 0)), c, d})
      {:monitor, _pid, :long_schedule, info} ->
        {a, b, c, d} = acc
        drain_monitor({a, b, c + 1, max(d, Keyword.get(info, :timeout, 0))})
      {:monitor, _, _, _} -> drain_monitor(acc)
    after 0 -> acc
    end
  end
end

port = String.to_integer(System.get_env("PORT") || "25700")
nconn = String.to_integer(System.get_env("NCONN") || "5000")
dur = String.to_integer(System.get_env("DUR") || "20")
hold_mb = String.to_integer(System.get_env("HOLD_MB") || "0")
kb = String.to_integer(System.get_env("PERCONN_KB") || "0")
Srv.init_counters()
:erlang.system_monitor(self(), [{:long_gc, 5}, {:long_schedule, 5}])
collector =
  if mode == "pg" do
    {:ok, pg} = Postgrex.start_link(socket_dir: "/tmp", port: String.to_integer(System.get_env("PG_PORT") || "54388"), username: "postgres", database: "dbcraft", pool_size: 1)
    spawn_link(fn -> Srv.collector(pg) end)
  end
ticker = spawn_link(&Srv.ticker/0)
if hold_mb > 0 do
  spawn_link(fn -> Srv.holder(hold_mb, System.get_env("HOLD_KIND") || "bins") end)
  Process.sleep(6000)
end
mem0 = :erlang.memory(:total); rss0 = Srv.rss_kb()
l = Srv.listen(port)
for _ <- 1..16, do: spawn_link(fn -> Srv.acceptor(l, mode, kb, collector) end)
IO.puts("SERVER listening port=#{port} mode=#{mode} schedulers=#{System.schedulers_online()} hold_mb=#{hold_mb} perconn_kb=#{kb} nconn=#{nconn}")
t_wait = Srv.mono()
wait = fn wait -> if :atomics.get(:persistent_term.get(:up), 1) >= nconn or Srv.mono() - t_wait > 120_000_000, do: :ok, else: (Process.sleep(100); wait.(wait)) end
wait.(wait)
up = :atomics.get(:persistent_term.get(:up), 1)
Process.sleep(1500)
mem1 = :erlang.memory(:total); rss1 = Srv.rss_kb()
pids = Enum.take(for({p} <- :ets.tab2list(:conns), do: p), 300)
pmem = Enum.map(pids, fn p -> case Process.info(p, :memory) do {:memory, m} -> m; _ -> 0 end end)
Srv.drain_monitor()
f0 = Srv.total(); t0 = Srv.mono()
Process.sleep(dur * 1000)
f1 = Srv.total(); t1 = Srv.mono()
secs = (t1 - t0) / 1.0e6
send(ticker, {:get, self()})
ticks = receive do {:ticks, t} -> t end
late = for {ts, l} <- ticks, ts >= t0, ts <= t1, do: l
sorted = Enum.sort(late)
{ngc, maxgc, nls, maxls} = Srv.drain_monitor()
IO.puts("SOCKET mode=#{mode} conns=#{up} seconds=#{Float.round(secs, 2)} frames=#{f1 - f0} frames_per_s=#{round((f1 - f0) / secs)}")
IO.puts("MEMORY per_conn_beam_bytes=#{div(mem1 - mem0, max(up, 1))} per_conn_rss_bytes=#{div((rss1 - rss0) * 1024, max(up, 1))} sampled_process_avg_bytes=#{div(Enum.sum(pmem), max(length(pmem), 1))} rss_mb=#{div(rss1, 1024)} beam_total_mb=#{div(mem1, 1_048_576)}")
IO.puts("TICK50 n=#{length(late)} late_p50_us=#{Srv.pct(sorted, 0.5)} late_p99_us=#{Srv.pct(sorted, 0.99)} late_max_us=#{List.last(sorted)} (actual minus scheduled time on a 50 ms grid)")
IO.puts("MONITOR long_gc(>5ms) count=#{ngc} max_ms=#{maxgc} long_schedule(>5ms) count=#{nls} max_ms=#{maxls}")
if collector do
  send(collector, {:get, self()})
  stats = receive do {:stats, s} -> s end
  stats = Enum.filter(stats, fn {rows, _, _, _, _, _} -> rows > 0 end)
  avg = fn i -> if stats == [], do: 0, else: div(Enum.sum(for(s <- stats, do: elem(s, i))), length(stats)) end
  mx = fn i -> if stats == [], do: 0, else: Enum.max(for(s <- stats, do: elem(s, i))) end
  IO.puts("PGBATCH ticks_with_data=#{length(stats)} rows_per_tick_avg=#{avg.(0)} build_us_avg=#{avg.(1)} copy_us_avg=#{avg.(2)} consume_us_avg=#{avg.(3)} busy_us_avg=#{avg.(4)} busy_us_max=#{mx.(4)} flush_late_us_max=#{mx.(5)}")
end
System.halt(0)
