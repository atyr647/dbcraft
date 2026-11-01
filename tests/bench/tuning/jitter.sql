-- How steady is the machine itself?  A backend spins on clock_timestamp() (no I/O, no locks, no catalog) for p_seconds and records every pause in its own progress.
-- Any gap here is the operating system / hypervisor not running the process (descheduling, CPU steal, throttling), not PostgreSQL work.
-- Run alongside a trial, or on its own:   psql -f tests/bench/tuning/jitter.sql -c "select * from tune.jitter(45)"
create schema if not exists tune;
create or replace function tune.jitter(p_seconds int default 30)
returns table (iterations bigint, max_gap_ms float8, gaps_over_5ms int, gaps_over_20ms int, gaps_over_50ms int, gaps_over_100ms int) language plpgsql as $$
declare t0 timestamptz := clock_timestamp(); t timestamptz; prev timestamptz := clock_timestamp(); gap float8; mx float8 := 0; n bigint := 0; g5 int := 0; g20 int := 0; g50 int := 0; g100 int := 0;
begin
    loop
        t := clock_timestamp();
        gap := extract(epoch from t - prev) * 1000;
        if gap > mx then mx := gap; end if;
        if gap > 5 then g5 := g5 + 1; end if;
        if gap > 20 then g20 := g20 + 1; end if;
        if gap > 50 then g50 := g50 + 1; end if;
        if gap > 100 then g100 := g100 + 1; end if;
        prev := t; n := n + 1;
        exit when t > t0 + make_interval(secs => p_seconds);
    end loop;
    return query select n, mx, g5, g20, g50, g100;
end $$;
