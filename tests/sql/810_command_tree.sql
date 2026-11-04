-- The command graph as rows and the `commands` packet generated from it (sql/810).
-- Byte-for-byte against recordings of the real 26.3 server for every permission level that has a recording: level 0 = the standard capture (play_nocomp), levels 1 to 4 =
-- play_op1 .. play_op4 (tools/bootstrap.sh records them: an operator of each level joins the throwaway vanilla server).  Without a recording a check is skipped with a notice.
\ir _harness.sql

select count(*) > 0 as loaded from mc.cmd_node \gset
\if :loaded
  select t.eq('the graph has one root', (select count(*) from mc.cmd_node where kind = 0)::int, 1);
  select t.eq('every edge points at existing nodes', (select count(*) from mc.cmd_child c where not exists (select 1 from mc.cmd_node n where n.id = c.child)
                                                                                                 or not exists (select 1 from mc.cmd_node n where n.id = c.parent))::int, 0);
  select t.eq('a literal or argument has a name, the root has none', (select count(*) from mc.cmd_node where (kind = 0) <> (name is null))::int, 0);
  select t.eq('an argument has a parser, nothing else has', (select count(*) from mc.cmd_node where (kind = 2) <> (argtype is not null))::int, 0);
  select t.eq('the root is node 0 and every other node is reachable from it', (select count(*) from mc.cmd_tree_order(4))::int, (select count(*) from mc.cmd_node)::int);
  select t.is_true('the level 4 numbering is the identity (the graph is stored in the order the real server numbers it)',
                   (select bool_and(old_id = new_id) from mc.cmd_tree_order(4)));
  select t.is_true('levels 0 and 1 see the same graph, higher levels see more',
                   (select (select nodes from mc.cmd_tree_cache where level = 0) = (select nodes from mc.cmd_tree_cache where level = 1)
                       and (select nodes from mc.cmd_tree_cache where level = 1) < (select nodes from mc.cmd_tree_cache where level = 2)
                       and (select nodes from mc.cmd_tree_cache where level = 2) < (select nodes from mc.cmd_tree_cache where level = 3)
                       and (select nodes from mc.cmd_tree_cache where level = 3) < (select nodes from mc.cmd_tree_cache where level = 4)));
  select t.eq('the cache is what the generator makes', (select body from mc.cmd_tree_cache where level = 2), (select body from mc.cmd_tree_body(2)));
  select t.eq('net.commands_body clamps the level', net.commands_body(9), (select body from mc.cmd_tree_cache where level = 4));
  do $do$
  declare j net.join_info := net.default_join_info(1); b0 bytea; b4 bytea;
  begin
    select body into b0 from net.play_entry_packets(1, j) where packet = 'minecraft:commands';
    j.op_level := 4;
    select body into b4 from net.play_entry_packets(1, j) where packet = 'minecraft:commands';
    perform t.eq('the join burst sends the packet of the player''s level: 0', b0, (select body from mc.cmd_tree_cache where level = 0));
    perform t.eq('the join burst sends the packet of the player''s level: 4 for an operator', b4, (select body from mc.cmd_tree_cache where level = 4));
  end $do$;
  select t.eq('the packet is framed with the commands packet id', (select mc.pkt_commands(0)), mc.cb('commands', net.commands_body(0)));

  drop table if exists t.cap810, t.rec810;
  create table t.cap810 (idx int, dir text, state text, pid int, name text, len int, hex text);
  create table t.rec810 (lvl int, capture text, frame bytea);
  \copy t.cap810 from program 'python3 tools/capture_to_tsv.py play_nocomp'
  insert into t.rec810 select 0, 'play_nocomp', decode(hex, 'hex') from t.cap810 where name = 'minecraft:commands' and dir = 'clientbound' order by idx limit 1;
  truncate t.cap810;
  \copy t.cap810 from program 'python3 tools/capture_to_tsv.py play_op1'
  insert into t.rec810 select 1, 'play_op1', decode(hex, 'hex') from t.cap810 where name = 'minecraft:commands' and dir = 'clientbound' order by idx limit 1;
  truncate t.cap810;
  \copy t.cap810 from program 'python3 tools/capture_to_tsv.py play_op2'
  insert into t.rec810 select 2, 'play_op2', decode(hex, 'hex') from t.cap810 where name = 'minecraft:commands' and dir = 'clientbound' order by idx limit 1;
  truncate t.cap810;
  \copy t.cap810 from program 'python3 tools/capture_to_tsv.py play_op3'
  insert into t.rec810 select 3, 'play_op3', decode(hex, 'hex') from t.cap810 where name = 'minecraft:commands' and dir = 'clientbound' order by idx limit 1;
  truncate t.cap810;
  \copy t.cap810 from program 'python3 tools/capture_to_tsv.py play_op4'
  insert into t.rec810 select 4, 'play_op4', decode(hex, 'hex') from t.cap810 where name = 'minecraft:commands' and dir = 'clientbound' order by idx limit 1;
  do $do$
  declare r record; l int;
  begin
    for l in 0 .. 4 loop
      select * into r from t.rec810 where lvl = l;
      if not found then raise notice 'SKIPPED level % (no recording in the capture directories)', l; continue; end if;
      perform t.eq('level ' || l || ': the generated commands packet is byte-identical to the recording ' || r.capture || ' (' || length(r.frame) || ' bytes)', mc.pkt_commands(l), r.frame);
    end loop;
    if not exists (select 1 from t.rec810) then raise notice 'SKIPPED the byte-for-byte comparison: no recordings'; end if;
  end $do$;
\else
  do $$ begin raise notice 'SKIPPED the command graph is not loaded (tools/load_command_tree.py needs the recording play_op4)'; end $$;
\endif
