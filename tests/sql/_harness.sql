-- Tiny assertion helpers.  Every test file starts with \ir _harness.sql and ends by printing a summary.
create schema if not exists t;
create or replace function t.eq(name text, got anyelement, want anyelement) returns void language plpgsql as $$
begin
  if got is not distinct from want then
    raise notice 'ok   %', name;
  else
    raise exception 'FAIL % : got % want %', name, got, want;
  end if;
end $$;
create or replace function t.is_true(name text, cond boolean) returns void language plpgsql as $$
begin
  if coalesce(cond, false) then raise notice 'ok   %', name; else raise exception 'FAIL % : condition false/null', name; end if;
end $$;
create or replace function t.raises(name text, stmt text) returns void language plpgsql as $$
begin
  begin execute stmt; exception when others then raise notice 'ok   % (raised: %)', name, sqlerrm; return; end;
  raise exception 'FAIL % : expected an error', name;
end $$;
