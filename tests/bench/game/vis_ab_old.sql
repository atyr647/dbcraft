-- A side of the A/B: the tick calls the neighbourhood version (what the tree before this work calls) through a wrapper
create or replace function mc.refresh_visibility_vis() returns table(added int, removed int) language plpgsql as $$
begin
  return query select * from mc.refresh_visibility_vis_nb();
end $$;
