-- the statements the clients run (dynamic SQL so one pgbench script per table kind is enough; the overhead is the same in every case and small next to 500 row updates)
create or replace function par.upd_sep(kind text, n int) returns void language plpgsql as $$
begin execute format('update par.%s_sep_%s set a = a + 1, b = b + 1, c = c + 1, d = d + 1', kind, n); end $$;
create or replace function par.upd_shared(kind text, n int) returns void language plpgsql as $$
begin execute format('update par.%s_shared set a = a + 1, b = b + 1, c = c + 1, d = d + 1 where id between %s and %s', kind, n * 500 + 1, n * 500 + 500); end $$;
