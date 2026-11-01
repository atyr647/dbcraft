-- EXPERIMENT ONLY (not part of sql/): measure what the row lock in mc.ensure_chunk_current costs.  The original runs `select * ... for update` on the chunk row on every call,
-- including every cache hit of mc.chunk_packet; a row lock is a write (page dirtied, WAL record).  This version first looks without locking and only locks when there is work.
-- The function belongs to the world module (sql/220); a real fix is for its owner to make.  Behaviour is identical except for the lock taken on a clean chunk.
create or replace function mc.ensure_chunk_current(p_dim text, p_cx int, p_cz int) returns boolean language plpgsql volatile as $$
declare
    c mc.chunk%rowtype;
    h record;
begin
    perform 1 from mc.chunk k where k.dimension = p_dim and k.cx = p_cx and k.cz = p_cz and not k.dirty and not k.hm_dirty and k.hm_world_surface is not null;
    if found then return false; end if;
    select * into c from mc.chunk k where k.dimension = p_dim and k.cx = p_cx and k.cz = p_cz for update;
    if not found then return false; end if;
    if not c.dirty and not c.hm_dirty and c.hm_world_surface is not null then return false; end if;
    if c.hm_dirty or c.hm_world_surface is null then
        select * into h from mc.compute_heightmaps(p_dim, p_cx, p_cz);
        update mc.chunk k set hm_motion_blocking = h.motion_blocking, hm_motion_blocking_no_leaves = h.motion_blocking_no_leaves,
                              hm_world_surface = h.world_surface, hm_dirty = false
         where k.dimension = p_dim and k.cx = p_cx and k.cz = p_cz;
    end if;
    perform mc.compute_light(p_dim, p_cx, p_cz);
    update mc.chunk k set dirty = false where k.dimension = p_dim and k.cx = p_cx and k.cz = p_cz;
    return true;
end $$;
