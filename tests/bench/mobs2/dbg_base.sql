-- debugging aid for tests/sql/940 part B: which lanes differ between mc.entity_auto_base and the stateful simulation (run after the test's setup of t.lanes / t.sim_base in a scratch database)
select (l.gx <> 0 or l.gz <> 0) as walking, sqrt(l.gx ^ 2 + l.gz ^ 2) * 3 * 4096 > 40 as fast, count(*), min(l.t0 + k * 17 - l.t0) as k0
  from t.lanes l cross join lateral generate_series(0, 5) k
  cross join lateral mc.entity_auto_base(l.t0, l.every, l.slot, l.x0, l.z0, l.y, l.gx, l.gz, l.yaw, l.lend, l.born, l.sqx, l.sqy, l.sqz, l.syaw, l.last, l.t0 + k * 17) a
  cross join lateral t.sim_base(l.t0, l.every, l.slot, l.x0, l.z0, l.y, l.gx, l.gz, l.yaw, l.lend, l.born, l.sqx, l.sqy, l.sqz, l.syaw, l.last, l.t0 + k * 17) s
 where a.bx is distinct from s.bx or a."by" is distinct from s."by" or a.bz is distinct from s.bz or a.byaw is distinct from s.byaw or a.blast is distinct from s.blast
 group by 1, 2;
