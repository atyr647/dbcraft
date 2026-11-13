-- Light engine, part 4: the propagation.  See docs/LIGHT.md.
--
-- Vanilla's engine (net.minecraft.world.level.lighting) ends in a fixed point that does not depend on the order of the updates: the light of a cell is the larger of
-- its own emission and (the light of a neighbour) - max(1, dampening of the cell), a neighbour that is not shut off by occluding face shapes; sky light starts with
-- 15 in every "source" cell, the cells above the highest cell that has dampening (or a face-occluding edge), block light with the emission of the block.  Since
-- every step costs at least 1, the cells of light >= L can be computed from the cells of light >= L + 1 alone: this file computes the level sets from 15 down to 1
-- as breadth-first waves, one level per statement, over bit sets (one bit(4096) per section and level), so a wave costs a handful of string operations per section
-- instead of one row per cell.  A cell reached at a higher level is final (visited), so each level only expands the cells that are new at the level before.
--
-- Work tables (temporary, kept for the session, emptied by mc.light_work_init):
--   lw_sec   the sections taking part: passable cells, sky source cells, the neighbour sections (n0 x-1, n1 x+1, n2 z-1, n3 z+1, n4 y-1, n5 y+1; NULL when not present)
--   lw_em    the cells that start a wave at a level: (section, level, cells): sky 15 for the sources, the emitters for block light
--   lw_run   per kind (1 sky, 2 block) and section: visited cells and the four level bit-planes
--   lw_fr    the cells that were new at the level before (the wave front)
create or replace function mc.light_work_init() returns void language plpgsql as $$
begin
    if to_regclass('pg_temp.lw_sec') is null then
        create temp table lw_sec (
            i int primary key, cx int not null, sy int not null, cz int not null,
            pass bit(4096) storage plain not null,               -- cells light may enter (dampening below 15)
            src  bit(4096) storage plain,                        -- sky: cells above the highest light-stopping cell of their column (NULL: none)
            em_lvl int[], em_mask bit(4096)[],                   -- block: emitting cells per level
            sh   bit(4096) storage plain,                        -- cells whose state uses its occlusion shape (NULL: none)
            stored boolean not null default false,               -- a stored section row exists
            n0 int, n1 int, n2 int, n3 int, n4 int, n5 int,
            -- occlusion shapes (NULL: nothing blocked): ia<side> the cells that may receive light from the neighbour on that side inside the section (side 0 down, 1 up,
            -- 2 north, 3 south, 4 west, 5 east), rc<j> the cells of neighbour n<j> that may receive from this section
            ia0 bit(4096) storage plain, ia1 bit(4096) storage plain, ia2 bit(4096) storage plain, ia3 bit(4096) storage plain, ia4 bit(4096) storage plain, ia5 bit(4096) storage plain,
            rc0 bit(4096) storage plain, rc1 bit(4096) storage plain, rc2 bit(4096) storage plain, rc3 bit(4096) storage plain, rc4 bit(4096) storage plain, rc5 bit(4096) storage plain)
            on commit delete rows;
        create unique index lw_sec_pos on lw_sec (cx, sy, cz);
        create temp table lw_em (i int not null, lvl int not null, m bit(4096) storage plain not null) on commit delete rows;
        create index lw_em_lvl on lw_em (lvl);
        create temp table lw_run (
            kind smallint not null, i int not null, vis bit(4096) storage plain not null,
            c0 bit(4096) storage plain not null, c1 bit(4096) storage plain not null, c2 bit(4096) storage plain not null, c3 bit(4096) storage plain not null,
            primary key (kind, i)) on commit delete rows;
        create temp table lw_fr (i int not null, f bit(4096) storage plain not null) on commit delete rows;
        create temp table lw_chunk (cx int not null, cz int not null, tgt boolean not null, top int, carry bit(256), done boolean not null default false,
                                    lowest int, primary key (cx, cz)) on commit delete rows;
        create temp table lw_lim (cx int, cz int, lim int, primary key (cx, cz)) on commit delete rows;
        create temp table lw_ne (cx int, cz int, sy int) on commit delete rows;
        create temp table lw_out (cx int, cz int, idx int, sky_kind text, sky bytea, block_kind text, block bytea) on commit delete rows;
        create temp table lw_chg (cx int not null, cz int not null) on commit delete rows;                  -- chunks whose light rows changed in the last mc.light_region
        create temp table lw_pal (cx int not null, sy int not null, cz int not null, has_em boolean not null, has_sh boolean not null) on commit delete rows;
        create temp table lw_shc (ax int not null, ay int not null, az int not null, f smallint[] not null) on commit delete rows;      -- cells with an occlusion shape (absolute position)
        create index lw_shc_pos on lw_shc (ax, ay, az);
        create temp table lw_occ (cx int not null, sy int not null, cz int not null, side smallint not null, m bit(4096) storage plain not null) on commit delete rows;
        create index lw_occ_pos on lw_occ (cx, sy, cz);
    else
        delete from lw_sec; delete from lw_em; delete from lw_run; delete from lw_fr; delete from lw_chunk; delete from lw_lim; delete from lw_ne; delete from lw_out; delete from lw_chg;
        delete from lw_pal; delete from lw_shc; delete from lw_occ;
    end if;
end $$;

-- Link the neighbour sections of lw_sec.
create or replace function mc.light_link() returns void language plpgsql volatile as $$
begin
  update lw_sec s set n0 = (select t.i from lw_sec t where t.cx = s.cx - 1 and t.sy = s.sy and t.cz = s.cz),
                      n1 = (select t.i from lw_sec t where t.cx = s.cx + 1 and t.sy = s.sy and t.cz = s.cz),
                      n2 = (select t.i from lw_sec t where t.cx = s.cx and t.sy = s.sy and t.cz = s.cz - 1),
                      n3 = (select t.i from lw_sec t where t.cx = s.cx and t.sy = s.sy and t.cz = s.cz + 1),
                      n4 = (select t.i from lw_sec t where t.cx = s.cx and t.sy = s.sy - 1 and t.cz = s.cz),
                      n5 = (select t.i from lw_sec t where t.cx = s.cx and t.sy = s.sy + 1 and t.cz = s.cz);
end $$;

-- The waves of one kind (1 sky, 2 block): reads lw_sec / lw_em, leaves the level planes of every section in lw_run.
create or replace function mc.light_waves(p_kind int) returns void language plpgsql volatile set plan_cache_mode = force_generic_plan as $$
declare
    lv      int;
    top     int;
    n       int;
begin
    select coalesce(max(e.lvl), 0) into top from lw_em e;
    insert into lw_run select p_kind, s.i, mc.lk_zero(), mc.lk_zero(), mc.lk_zero(), mc.lk_zero(), mc.lk_zero() from lw_sec s;
    delete from lw_fr;
    if top = 0 then return; end if;
    for lv in reverse top .. 1 loop
        with p as (select p0.i, p0.f, s.n0, s.n1, s.n2, s.n3, s.n4, s.n5, s.ia0, s.ia1, s.ia2, s.ia3, s.ia4, s.ia5, s.rc0, s.rc1, s.rc2, s.rc3, s.rc4, s.rc5
                     from lw_fr p0 join lw_sec s on s.i = p0.i),
        c as (
            select i as t, (((f << 1) & coalesce(ia4, ~mc.lk_x0())) | ((f >> 1) & coalesce(ia5, ~mc.lk_x15())) | ((f << 16) & coalesce(ia3, ~mc.lk_z15()))
                          | ((f >> 16) & coalesce(ia2, ~mc.lk_z0())) | ((f << 256) & coalesce(ia1, ~mc.lk_y15())) | ((f >> 256) & coalesce(ia0, ~mc.lk_y0()))) as m from p
            union all select n0, (f << 15)   & coalesce(rc0, mc.lk_x15()) from p where n0 is not null
            union all select n1, (f >> 15)   & coalesce(rc1, mc.lk_x0())  from p where n1 is not null
            union all select n2, (f >> 240)  & coalesce(rc2, mc.lk_z15()) from p where n2 is not null
            union all select n3, (f << 240)  & coalesce(rc3, mc.lk_z0())  from p where n3 is not null
            union all select n4, (f >> 3840) & coalesce(rc4, mc.lk_y15()) from p where n4 is not null
            union all select n5, (f << 3840) & coalesce(rc5, mc.lk_y0())  from p where n5 is not null),
        g as (select t as i, bit_or(m) as m from c group by t),
        cand as (select g.i, g.m & s.pass as m from g join lw_sec s on s.i = g.i
                 union all select e.i, e.m from lw_em e where e.lvl = lv),
        nf as materialized (
            select c.i, bit_or(c.m) & ~r.vis as f from cand c join lw_run r on r.kind = p_kind and r.i = c.i group by c.i, r.vis),
        nz as materialized (select i, f from nf where bit_count(f) > 0),
        upd as (
            update lw_run r set vis = r.vis | z.f,
                   c0 = case when (lv & 1) <> 0 then r.c0 | z.f else r.c0 end, c1 = case when (lv & 2) <> 0 then r.c1 | z.f else r.c1 end,
                   c2 = case when (lv & 4) <> 0 then r.c2 | z.f else r.c2 end, c3 = case when (lv & 8) <> 0 then r.c3 | z.f else r.c3 end
              from nz z where r.kind = p_kind and r.i = z.i returning 1),
        del as (delete from lw_fr returning 1)
        insert into lw_fr select i, f from nz;
        get diagnostics n = row_count;
        if n = 0 and not exists (select 1 from lw_em e where e.lvl < lv) then exit; end if;
    end loop;
end $$;
