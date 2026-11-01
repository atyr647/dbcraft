# Isolated Postgres ingest cost for one tick's packets: binary COPY vs multi-row insert from arrays. Needs a cluster on PG_PORT (default 54388).
Mix.install([{:postgrex, "== 0.17.5"}])
import Bitwise
{:ok, pg} = Postgrex.start_link(socket_dir: "/tmp", port: String.to_integer(System.get_env("PG_PORT") || "54388"), username: "postgres", database: "dbcraft", pool_size: 1)
Postgrex.query!(pg, "create schema if not exists net", [])
Postgrex.query!(pg, "drop table if exists net.inbox", [])
Postgrex.query!(pg, "create unlogged table net.inbox (tick bigint, conn_id int, body bytea)", [])
mono = fn -> :erlang.monotonic_time(:microsecond) end
header = <<"PGCOPY\n", 255, ?\r, ?\n, 0, 0::32, 0::32>>
for n <- [10_000, 25_000, 100_000] do
  bodies = for i <- 1..n, do: <<34, 0x1C, i::64, 0::200>>      # 34-byte packets
  ids = for i <- 1..n, do: rem(i, 5000)
  copy = fn ->
    rows = for {id, b} <- Enum.zip(ids, bodies), do: <<3::16, 8::32, 1::64, 4::32, id::32, byte_size(b)::32, b::binary>>
    {:ok, _} = Postgrex.transaction(pg, fn c -> Enum.into([header, rows, <<-1::16>>], Postgrex.stream(c, "COPY net.inbox FROM STDIN WITH (FORMAT binary)", [])) end)
  end
  unnest = fn -> Postgrex.query!(pg, "insert into net.inbox select 1, c, b from unnest($1::int[], $2::bytea[]) u(c, b)", [ids, bodies]) end
  values = fn ->
    # one multi-row INSERT ... VALUES ($1,$2,$3),($4,...) per chunk of 20,000 rows (Postgres allows at most 65,535 parameters per statement)
    for chunk <- Enum.chunk_every(Enum.zip(ids, bodies), 20_000) do
      sql = "insert into net.inbox values " <> Enum.map_join(0..(length(chunk) - 1), ",", fn k -> "($#{3 * k + 1}::bigint,$#{3 * k + 2}::int,$#{3 * k + 3}::bytea)" end)
      Postgrex.query!(pg, sql, Enum.flat_map(chunk, fn {id, b} -> [1, id, b] end))
    end
  end
  consume = fn -> Postgrex.query!(pg, "with c as (delete from net.inbox returning 1) select count(*) from c", []) end
  best = fn f -> Enum.min(for _ <- 1..8, do: (Postgrex.query!(pg, "truncate net.inbox", []); {t, _} = :timer.tc(f); t)) end
  bc = best.(copy); bu = best.(unnest); bv = best.(values)
  copy.(); {tc, _} = :timer.tc(consume)
  IO.puts("PGINGEST packets=#{n} copy_binary_ms=#{Float.round(bc / 1000, 2)} unnest_insert_ms=#{Float.round(bu / 1000, 2)} multirow_values_ms=#{Float.round(bv / 1000, 2)} consume_delete_ms=#{Float.round(tc / 1000, 2)}")
end
System.halt(0)
