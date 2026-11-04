# Idle cost, chat from real clients and the tick tail: the second round

[PERF-IDLE.md](PERF-IDLE.md) closed the scoreboard's idle losses for the PL/Python gateway and for scripted clients, and left four things open (its "What is left"): an empty server still used a little more CPU than vanilla
(0.022-0.030 cores against 0.017-0.019), idle players still cost a full tick, the lane for urgent chat only took chat that had nothing but `client_tick_end` and movement ahead of it (real clients send more), and the p99 of the tick
(and so of chat) followed the longest tick.  This document is that round: what was measured first, what changed, what the numbers are now with vanilla re-measured in the same session, what did not work and what is still a loss.

@@RESULT@@

## A correction to the numbers of PERF-IDLE.md (read this first)

`tools/scoreboard/run.py` measured dbcraft's CPU as the CPU of the PostgreSQL process tree.  The Rust gateway is not a child of the postmaster, so **the "CPU cores" of every Rust row in PERF-IDLE.md (0.030, 0.076, 0.107, ...) leaves the gateway process out**
(the PL/Python gateway is a backend inside the tree, its rows were right).  `dbcraft.sh start` now writes the gateway's pid to `$SCORE_OUT/gateway.pid` and the runner adds that process.  At 200 idle players the gateway costs 0.028 cores
(4,000 `client_tick_end` frames a second: one `read` each and about 1,000 context switches a second), so that row was 0.107 and is 0.11-0.15 cores with it.  Every number below includes the gateway; the "before" column is the code this work started from (`046d1e2`), measured the same way, in the same session.

@@BODY@@
