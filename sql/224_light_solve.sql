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
    create temp table if not exists lw_sec (
        i int primary key, cx int not null, sy int not null, cz int not null,
        pass bit(4096) storage plain not null,               -- cells light may enter (dampening below 15)
        src  bit(4096) storage plain,                        -- sky: cells above the highest light-stopping cell of their column (NULL: none)
        em_lvl int[], em_mask bit(4096)[],                   -- block: emitting cells per level
        sh   bit(4096) storage plain,                        -- cells whose state uses its occlusion shape (NULL: none)
        stored boolean not null default false,               -- a stored section row exists
        n0 int, n1 int, n2 int, n3 int, n4 int, n5 int) on commit delete rows;
    create unique index if not exists lw_sec_pos on lw_sec (cx, sy, cz);
    create temp table if not exists lw_em (i int not null, lvl int not null, m bit(4096) storage plain not null) on commit delete rows;
    create index if not exists lw_em_lvl on lw_em (lvl);
    create temp table if not exists lw_run (
        kind smallint not null, i int not null, vis bit(4096) storage plain not null,
        c0 bit(4096) storage plain not null, c1 bit(4096) storage plain not null, c2 bit(4096) storage plain not null, c3 bit(4096) storage plain not null,
        primary key (kind, i)) on commit delete rows;
    create temp table if not exists lw_fr (i int not null, f bit(4096) storage plain not null) on commit delete rows;
    create temp table if not exists lw_chunk (cx int not null, cz int not null, tgt boolean not null, top int, carry bit(256), done boolean not null default false,
                                              lowest int, primary key (cx, cz)) on commit delete rows;
    delete from lw_sec; delete from lw_em; delete from lw_run; delete from lw_fr; delete from lw_chunk;
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
        with p as (select i, f from lw_fr),
        c as (
            select i as t, (((f << 1) & ~mc.lk_x0()) | ((f >> 1) & ~mc.lk_x15()) | ((f << 16) & ~mc.lk_z15()) | ((f >> 16) & ~mc.lk_z0())
                          | ((f << 256) & ~mc.lk_y15()) | ((f >> 256) & ~mc.lk_y0())) as m from p
            union all select s.n0, (p.f << 15)   & mc.lk_x15() from p join lw_sec s on s.i = p.i where s.n0 is not null
            union all select s.n1, (p.f >> 15)   & mc.lk_x0()  from p join lw_sec s on s.i = p.i where s.n1 is not null
            union all select s.n2, (p.f >> 240)  & mc.lk_z15() from p join lw_sec s on s.i = p.i where s.n2 is not null
            union all select s.n3, (p.f << 240)  & mc.lk_z0()  from p join lw_sec s on s.i = p.i where s.n3 is not null
            union all select s.n4, (p.f >> 3840) & mc.lk_y15() from p join lw_sec s on s.i = p.i where s.n4 is not null
            union all select s.n5, (p.f << 3840) & mc.lk_y0()  from p join lw_sec s on s.i = p.i where s.n5 is not null),
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
