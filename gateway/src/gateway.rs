//! The gateway: one thread, one epoll loop, sockets from `std`, the database through libpq.  Behaves exactly like the reference gateway written as database code
//! (sql/optional/dev_gateway_online.sql) as seen from SQL: per tick, in ONE transaction and in this order:
//!   net.on_connect for sockets accepted -> inbound frames into net.inbox -> net.auth_begun -> session verdicts into net.auth_result -> net.apply_auth_results()
//!   -> the server tick -> net.on_disconnect for sockets the client closed -> net.drain_outbox() -> net.gateway_ctl() -> statistics.
//! After the commit the drained bytes are queued per socket (encrypted when the connection is), control rows are applied, and sockets are written.
//! If the transaction fails it is rolled back; the tick's inbound frames are dropped (a poison frame must not stall the server), everything else is retried next tick.

use crate::config::Config;
use crate::ffi::ossl::{Cfb8Stream, RsaKey};
use crate::ffi::pq::{self, Param, Pg, PgError};
use crate::generators::Generators;
use crate::ffi::sys::{self, Epoll, EventFd, EPOLLERR, EPOLLHUP, EPOLLIN, EPOLLOUT, EPOLLRDHUP};
use crate::keypkt::parse_key_packet;
use crate::limits::{LimitConfig, Limits};
use crate::maint::Maintenance;
use crate::mojang::{Outcome, PoolConfig, SessionPool, Verdict};
use crate::reader::{Await, Item, Reader, ReaderLimits};
use crate::wq::WriteQueue;
use dbcraft_gateway_core::hash::server_hash;
use std::collections::{HashMap, HashSet};
use std::io::{ErrorKind, Read, Write};
use std::net::{IpAddr, Shutdown, TcpListener, TcpStream};
use std::os::fd::AsRawFd;
use std::sync::Arc;
use std::time::{Duration, Instant};

/// name of the prepared statement of the lean tick (the tick function and the probe in one statement)
const LEAN_STMT: &str = "dbcraft_lean_tick";
/// the control row (statistics, stop flag) is written every this many lean ticks: once a second at 20 Hz
const LEAN_CONTROL_EVERY: u32 = 20;

const LISTENER: u64 = 0;
const WAKE: u64 = u64::MAX;
const SIGNALS: u64 = u64::MAX - 1;

struct Conn {
    stream: TcpStream,
    ip: IpAddr,
    reader: Reader,
    enc: Option<Cfb8Stream>,
    wq: WriteQueue,
    /// the database asked to close after the last queued byte
    closing: bool,
    want_out: bool,
    last_read: Instant,
    last_frame: Instant,
    last_write: Instant,
}

#[derive(Default, Clone)]
struct Stats {
    ticks: u64,
    late: u64,
    tick_ms_sum: f64,
    tick_ms_max: f64,
    db_ms_sum: f64,
    frames_in: u64,
    bytes_in: u64,
    frames_out: u64,
    bytes_out: u64,
    rejected: u64,
    errors: u64,
    lean_ticks: u64,
    urgent_runs: u64,
    urgent_frames: u64,
    /// chat frames that reached the tick, by what kept the lane from taking them (see ChatFate)
    chat_late: u64,
    chat_blocked: u64,
    chat_behind_command: u64,
    chat_not_play: u64,
}

/// Packet ids (serverbound, play) the urgent chat lane needs to classify a frame without parsing it.
#[derive(Clone)]
struct UrgentIds {
    chat: u32,
    cmd: [u32; 2],
    tick_end: u32,
    pos: u32,
    pos_rot: u32,
    /// frames that may stand ahead of a chat frame of the same connection without making it wait (sorted): client_tick_end, the movement packets and, from the database
    /// (net.urgent_neutral_play_ids, sql/971), every other kind whose handling cannot change what a chat does or sends (docs/PERF-IDLE2.md, "Chat from real clients")
    neutral: Vec<u32>,
}

impl UrgentIds {
    fn is_neutral(&self, pid: u32) -> bool {
        self.neutral.binary_search(&pid).is_ok()
    }
}

/// The packet id of a frame (first VarInt), or None when it is not a plain id below 2^21.
fn frame_pid(payload: &[u8]) -> Option<u32> {
    let mut v: u32 = 0;
    for (i, b) in payload.iter().take(3).enumerate() {
        v |= ((b & 0x7f) as u32) << (7 * i);
        if b & 0x80 == 0 {
            return Some(v);
        }
    }
    None
}

/// Removes the client_tick_end frames of play connections that have fewer than two position packets in `frames`: the database ignores them (sql/800 has the argument).
fn drop_idle_tick_ends(frames: &mut Vec<(u64, Vec<u8>)>, ids: &UrgentIds, is_play: &dyn Fn(u64) -> bool) {
    let (tick_end, pos, pos_rot) = (ids.tick_end, ids.pos, ids.pos_rot);
    if !frames.iter().any(|(_, p)| frame_pid(p) == Some(tick_end)) {
        return;
    }
    let mut positions: HashMap<u64, u32> = HashMap::new();
    for (cid, p) in frames.iter() {
        let pid = frame_pid(p);
        if pid == Some(pos) || pid == Some(pos_rot) {
            *positions.entry(*cid).or_insert(0) += 1;
        }
    }
    frames.retain(|(cid, p)| !(frame_pid(p) == Some(tick_end) && positions.get(cid).copied().unwrap_or(0) < 2 && is_play(*cid)));
}

/// Which frames of `frames` (in arrival order) may be handled urgently: chat frames of play connections such that no frame ahead of them (any connection) is a command and no
/// frame ahead of them from the same connection is anything but chat, client_tick_end or a movement packet.  Returns indices into `frames`.
fn urgent_candidates(frames: &[(u64, Vec<u8>)], ids: &UrgentIds, is_play: &dyn Fn(u64) -> bool) -> Vec<usize> {
    let mut taken = Vec::new();
    let mut blocked: HashSet<u64> = HashSet::new();
    for (i, (cid, payload)) in frames.iter().enumerate() {
        let pid = match frame_pid(payload) {
            Some(p) => p,
            None => {
                blocked.insert(*cid);
                continue;
            }
        };
        if ids.cmd.contains(&pid) {
            break; // a command: it and everything after it waits for the tick, so commands and chat keep their arrival order
        } else if pid == ids.chat {
            if !blocked.contains(cid) && is_play(*cid) {
                taken.push(i);
            } else {
                blocked.insert(*cid);
            }
        } else if !ids.is_neutral(pid) {
            blocked.insert(*cid);
        }
    }
    taken
}

/// Why chat frames are not handled by the lane, counted over the frames the tick is about to take (what is left after the lane ran).  A frame the lane WOULD take now
/// (`takeable`) was left for the tick by timing: the tick was due, the runs per tick were used up, the run failed.  `blockers` counts the packet ids that blocked a
/// chat of their own connection (a histogram to look at when real clients' chat does not take the lane).
#[derive(Default, Debug, PartialEq)]
struct ChatFate {
    takeable: u64,
    blocked_by_kind: u64,
    behind_command: u64,
    not_play: u64,
    blockers: HashMap<u32, u64>,
}

fn urgent_fate(frames: &[(u64, Vec<u8>)], ids: &UrgentIds, is_play: &dyn Fn(u64) -> bool) -> ChatFate {
    let mut fate = ChatFate::default();
    let mut blocked: HashMap<u64, u32> = HashMap::new(); // connection -> the pid that blocked it (u32::MAX: an earlier chat that was not takeable)
    let mut command_seen = false;
    for (cid, payload) in frames.iter() {
        let pid = match frame_pid(payload) {
            Some(p) => p,
            None => {
                blocked.entry(*cid).or_insert(u32::MAX - 1);
                continue;
            }
        };
        if ids.cmd.contains(&pid) {
            command_seen = true;
        } else if pid == ids.chat {
            if command_seen {
                fate.behind_command += 1;
                blocked.entry(*cid).or_insert(u32::MAX);
            } else if let Some(b) = blocked.get(cid) {
                fate.blocked_by_kind += 1;
                *fate.blockers.entry(*b).or_insert(0) += 1;
            } else if !is_play(*cid) {
                fate.not_play += 1;
                blocked.insert(*cid, u32::MAX);
            } else {
                fate.takeable += 1;
            }
        } else if !ids.is_neutral(pid) {
            blocked.entry(*cid).or_insert(pid);
        }
    }
    fate
}

struct DrainRow {
    conn_id: u64,
    data: Vec<u8>,
    close: bool,
}

struct CtlRow {
    conn_id: u64,
    seq: i64,
    state: String,
    compression: Option<i32>,
    await_key: Option<Await>,
}

struct TickOut {
    drain: Vec<DrainRow>,
    ctl: Vec<CtlRow>,
    stop: bool,
}

pub struct Gateway {
    cfg: Config,
    tick: Duration,
    db: Pg,
    ep: Epoll,
    listener: TcpListener,
    wake: Arc<EventFd>,
    sigfd: sys::RawFd,
    rsa: RsaKey,
    pub_der: Vec<u8>,
    key_pkt: u32,
    pool: SessionPool,
    limits: Limits,
    /// the vacuum thread with its own connection (cfg.maintenance_s > 0), see maint.rs and docs/SOAK.md
    maint: Option<Maintenance>,
    conns: HashMap<u64, Conn>,
    next_id: u64,
    has_control: bool,
    // events of the current tick, delivered to the database at the next tick
    accepted: Vec<(u64, String)>,
    inbound: Vec<(u64, Vec<u8>)>,
    begun: Vec<u64>,
    dropped: Vec<u64>,
    verdicts: Vec<Verdict>,
    last_ctl: i64,
    rbuf: Vec<u8>,
    stats: Stats,
    reported: Stats,
    stats_window: Stats,
    stop: bool,
    start: Instant,
    /// packet ids for the urgent chat lane and the client_tick_end filter (None: both disabled or the ids are not available)
    urgent: Option<UrgentIds>,
    /// the urgent chat lane itself is on (config, and net.urgent_chat exists)
    urgent_on: bool,
    urgent_want: bool,
    urgent_runs: u32,
    urgent_cost_ms: f64,
    /// a chat frame was read since the last tick (the fate statistics only look at ticks that have one)
    urgent_seen_chat: bool,
    /// packet id -> chat frames of the same connection it kept from the lane (logged at shutdown)
    chat_blockers: HashMap<u32, u64>,
    /// ticks that ran lean since the control row was last written: (count, late, max ms, last ms)
    lean_pending: (u32, u32, f64, f64),
    /// `select <tick function>, net.gateway_pending($1)`
    lean_sql: String,
    /// chunk generator threads (cfg.generators > 0), woken when the probe after a tick finds chunk requests
    gens: Option<Generators>,
    gens_wanted: bool,
    /// (ms since start, tick ms, flags: 1 lean, 2 late) of every tick, kept only when cfg.tick_log names a file (written at shutdown)
    tick_samples: Vec<(u32, f32, u8)>,
}

fn log(start: Instant, msg: &str) {
    eprintln!("[gw {:9.3}] {}", start.elapsed().as_secs_f64(), msg);
}

fn db_setting(db: &mut Pg, key: &str) -> Result<Option<String>, PgError> {
    let r = db.query("select net.setting($1)", &[Param::text(pq::OID_TEXT, key)], false)?;
    Ok(r.text(0, 0))
}

impl Gateway {
    pub fn start(mut cfg: Config, sigfd: sys::RawFd) -> Result<Gateway, String> {
        let start = Instant::now();
        let mut db = Pg::connect(&cfg.database_url).map_err(|e| e.to_string())?;

        // settings kept in the database win over the defaults (not over a value set explicitly in the file/environment)
        let defaults = Config::default();
        if let Some(v) = db_setting(&mut db, "tick_ms").map_err(|e| e.to_string())? {
            if cfg.tick_ms == defaults.tick_ms {
                cfg.tick_ms = v.trim().parse().map_err(|_| format!("net.setting tick_ms is not a number: {v:?}"))?;
            }
        }
        if let Some(v) = db_setting(&mut db, "session_url").map_err(|e| e.to_string())? {
            if cfg.session_url == defaults.session_url {
                cfg.session_url = v;
            }
        }
        if let Some(v) = db_setting(&mut db, "session_timeout_s").map_err(|e| e.to_string())? {
            if cfg.session_timeout_ms == defaults.session_timeout_ms {
                let s: f64 = v.trim().parse().map_err(|_| format!("net.setting session_timeout_s is not a number: {v:?}"))?;
                cfg.session_timeout_ms = (s * 1000.0) as u64;
            }
        }
        cfg.validate()?;

        let key_pkt = db.exec("select net.pkt('login', 'serverbound', 'minecraft:key')").map_err(|e| e.to_string())?.int(0, 0).ok_or("net.pkt returned no id")? as u32;
        let has_control = db.exec("select to_regclass('net.gateway_control') is not null").map_err(|e| e.to_string())?.boolean(0, 0).unwrap_or(false);

        // a stop request that predates this process (left by an earlier run's shutdown) must not stop it at its first tick
        if has_control {
            db.exec("update net.gateway_control set stop = false").map_err(|e| e.to_string())?;
        }

        let rsa = RsaKey::generate(cfg.rsa_bits)?;
        let pub_der = rsa.public_der()?;
        db.query(
            "insert into net.server_key (id, public_der) values (1, $1) on conflict (id) do update set public_der = excluded.public_der, updated_at = now()",
            &[Param::bin(pq::OID_BYTEA, &pub_der)],
            false,
        )
        .map_err(|e| e.to_string())?;
        // sockets of a previous process are gone and their ids would be reused by this one
        let cleaned = db.exec("select net.gateway_start()").map_err(|e| e.to_string())?.int(0, 0).unwrap_or(0);

        let listener = TcpListener::bind(&cfg.listen).map_err(|e| format!("cannot listen on {}: {e}", cfg.listen))?;
        listener.set_nonblocking(true).map_err(|e| e.to_string())?;
        let ep = Epoll::new().map_err(|e| e.to_string())?;
        ep.add(listener.as_raw_fd(), EPOLLIN, LISTENER).map_err(|e| e.to_string())?;
        let wake = Arc::new(EventFd::new().map_err(|e| e.to_string())?);
        ep.add(wake.fd(), EPOLLIN, WAKE).map_err(|e| e.to_string())?;
        ep.add(sigfd, EPOLLIN, SIGNALS).map_err(|e| e.to_string())?;
        let pool = SessionPool::start(
            PoolConfig { base_url: cfg.session_url.clone(), timeout_ms: cfg.session_timeout_ms, workers: cfg.session_workers, retries: cfg.session_retries },
            Arc::clone(&wake),
        )?;
        let mut urgent_on = false;
        let urgent = if cfg.urgent_chat || cfg.skip_tick_end {
            let ids = db
                .exec("select mc.sid('chat'), mc.sid('chat_command'), mc.sid('chat_command_signed'), mc.sid('client_tick_end'), mc.sid('move_player_pos'), mc.sid('move_player_pos_rot'), mc.sid('move_player_rot'), mc.sid('move_player_status_only'), to_regprocedure('net.urgent_chat(bigint[],bytea[])') is not null")
                .ok();
            // the kinds besides tick end and movement that may stand ahead of a chat (sql/971); an older database has no such function: only the five of the first lane
            let extra: Vec<u32> = match db.exec("select case when to_regprocedure('net.urgent_neutral_play_ids()') is not null then array_to_string(net.urgent_neutral_play_ids(), ',') end") {
                Ok(r) => r.text(0, 0).unwrap_or_default().split(',').filter_map(|x| x.trim().parse().ok()).collect(),
                Err(_) => Vec::new(),
            };
            ids.and_then(|r| {
                let g = |i: usize| r.int(0, i).map(|v| v as u32);
                let have_fn = r.boolean(0, 8).unwrap_or(false);
                urgent_on = cfg.urgent_chat && have_fn;
                match (g(0), g(1), g(2), g(3), g(4), g(5), g(6), g(7)) {
                    (Some(chat), Some(c1), Some(c2), Some(n1), Some(n2), Some(n3), Some(n4), Some(n5)) => {
                        let mut neutral = vec![n1, n2, n3, n4, n5];
                        neutral.extend(extra.iter().copied().filter(|p| *p != chat && *p != c1 && *p != c2));
                        neutral.sort_unstable();
                        neutral.dedup();
                        Some(UrgentIds { chat, cmd: [c1, c2], tick_end: n1, pos: n2, pos_rot: n3, neutral })
                    }
                    _ => None,
                }
            })
        } else {
            None
        };
        let limits = Limits::new(LimitConfig {
            max_connections: cfg.max_connections,
            max_per_ip: cfg.max_connections_per_ip,
            new_per_ip_per_sec: cfg.new_connections_per_ip_per_sec,
            logins_per_ip_per_min: cfg.login_attempts_per_ip_per_min,
        });
        log(
            start,
            &format!(
                "listening on {} (tick {} ms, {}, inbox via {}, session server {}, {} stale connections cleaned, lean ticks {}, urgent chat {} ({} kinds may stand ahead of a chat), tick_end filter {})",
                cfg.listen, cfg.tick_ms, cfg.tick_fn, cfg.inbox_mode, cfg.session_url, cleaned, cfg.lean_ticks, if urgent_on { "on" } else { "off" },
                urgent.as_ref().map_or(0, |u| u.neutral.len()), if cfg.skip_tick_end && urgent.is_some() { "on" } else { "off" }
            ),
        );
        let maint = if cfg.maintenance_s > 0 { Some(Maintenance::spawn(&cfg.database_url, cfg.maintenance_s, &cfg.maintenance_tables)) } else { None };
        let tick_fn = cfg.tick_fn.clone();
        if cfg.generators > 0 {
            // a stop flag left by an earlier shutdown (tools/scoreboard/dbcraft.sh stop) would make every generator call return at once
            let _ = db.exec("update mc.generator_control set stop = false");
        }
        let gens = if cfg.generators > 0 { Some(Generators::spawn(&cfg.database_url, cfg.generators, cfg.generator_batch, cfg.generator_exit_idle_ms)) } else { None };
        Ok(Gateway {
            tick: Duration::from_millis(cfg.tick_ms),
            cfg,
            db,
            ep,
            listener,
            wake,
            sigfd,
            rsa,
            pub_der,
            key_pkt,
            pool,
            limits,
            maint,
            conns: HashMap::new(),
            next_id: 1,
            has_control,
            accepted: Vec::new(),
            inbound: Vec::new(),
            begun: Vec::new(),
            dropped: Vec::new(),
            verdicts: Vec::new(),
            last_ctl: 0,
            rbuf: vec![0u8; 65536],
            stats: Stats::default(),
            reported: Stats::default(),
            stats_window: Stats::default(),
            stop: false,
            start,
            urgent,
            urgent_on,
            urgent_want: false,
            urgent_runs: 0,
            urgent_cost_ms: 2.0,
            urgent_seen_chat: false,
            chat_blockers: HashMap::new(),
            lean_pending: (0, 0, 0.0, 0.0),
            lean_sql: format!("select {}, net.gateway_pending($1::bigint)", tick_fn),
            gens,
            gens_wanted: false,
            tick_samples: Vec::new(),
        })
    }

    pub fn run(&mut self) -> Result<(), String> {
        let mut events = Vec::with_capacity(1024);
        let mut sched = Instant::now() + self.tick;
        let mut last_sweep = Instant::now();
        let mut last_stats = Instant::now();
        let mut last_limit_sweep = Instant::now();
        let mut last_trim = Instant::now();
        while !self.stop {
            let now = Instant::now();
            let wait_ms = if sched > now { ((sched - now).as_micros() as u64 + 999) / 1000 } else { 0 };
            self.ep.wait(&mut events, wait_ms.min(1000) as i32).map_err(|e| format!("epoll_wait: {e}"))?;
            for i in 0..events.len() {
                let ev = events[i]; // copy out of the packed struct
                let (key, flags) = (ev.data, ev.events);
                match key {
                    LISTENER => self.accept_all(),
                    WAKE => self.wake.drain(),
                    SIGNALS => {
                        if sys::drain_signalfd(self.sigfd) {
                            log(self.start, "signal received: shutting down");
                            self.stop = true;
                        }
                    }
                    id => {
                        if flags & (EPOLLIN | EPOLLHUP | EPOLLERR | EPOLLRDHUP) != 0 {
                            self.on_readable(id);
                        }
                        if flags & EPOLLOUT != 0 {
                            self.flush(id);
                        }
                    }
                }
            }
            if self.urgent_want {
                self.urgent_want = false;
                self.run_urgent(sched);
            }
            let now = Instant::now();
            if now >= sched {
                let lateness = now - sched;
                let late = lateness > Duration::from_millis(10);
                if lateness > self.tick * 5 {
                    sched = now; // far behind: restart the schedule instead of running a burst of back-to-back ticks
                }
                sched += self.tick;
                self.run_tick(late);
                if last_sweep.elapsed() >= Duration::from_secs(1) {
                    last_sweep = Instant::now();
                    self.sweep_timeouts();
                }
                if last_stats.elapsed() >= Duration::from_secs(1) {
                    last_stats = Instant::now();
                    self.flush_stats();
                }
                if last_limit_sweep.elapsed() >= Duration::from_secs(60) {
                    last_limit_sweep = Instant::now();
                    self.limits.sweep(Instant::now());
                }
                if last_trim.elapsed() >= Duration::from_secs(60) {
                    last_trim = Instant::now();
                    let _ = self.db.exec("delete from net.gateway_stats where ts < now() - interval '1 hour'");
                }
            }
        }
        self.shutdown();
        Ok(())
    }

    // ---- sockets -------------------------------------------------------------------------------------------------------------------------------------

    fn accept_all(&mut self) {
        loop {
            match self.listener.accept() {
                Ok((stream, addr)) => {
                    let ip = addr.ip();
                    let now = Instant::now();
                    if !self.limits.connect(ip, now) {
                        self.stats.rejected += 1;
                        continue; // dropping the stream closes it
                    }
                    if stream.set_nonblocking(true).is_err() {
                        self.limits.disconnect(ip);
                        continue;
                    }
                    let _ = stream.set_nodelay(true);
                    let id = self.next_id;
                    self.next_id += 1;
                    if self.ep.add(stream.as_raw_fd(), EPOLLIN | EPOLLRDHUP, id).is_err() {
                        self.limits.disconnect(ip);
                        continue;
                    }
                    let reader = Reader::new(ReaderLimits { prelogin_max_frame: self.cfg.prelogin_max_frame, prelogin_max_bytes: self.cfg.prelogin_max_bytes });
                    self.conns.insert(
                        id,
                        Conn { stream, ip, reader, enc: None, wq: WriteQueue::new(), closing: false, want_out: false, last_read: now, last_frame: now, last_write: now },
                    );
                    self.accepted.push((id, ip.to_string()));
                }
                Err(e) if e.kind() == ErrorKind::WouldBlock => return,
                Err(e) if e.kind() == ErrorKind::Interrupted => continue,
                Err(e) => {
                    // typically EMFILE/ENFILE: log and back off so a level-triggered listener does not spin
                    log(self.start, &format!("accept failed: {e}"));
                    std::thread::sleep(Duration::from_millis(5));
                    return;
                }
            }
        }
    }

    fn drop_conn(&mut self, id: u64, notify: bool, why: &str) {
        if let Some(c) = self.conns.remove(&id) {
            let _ = self.ep.delete(c.stream.as_raw_fd());
            let _ = c.stream.shutdown(Shutdown::Write);
            self.limits.disconnect(c.ip);
            if notify {
                self.dropped.push(id);
            }
            if !why.is_empty() && why != "closed by the client" {
                log(self.start, &format!("connection {id} ({}) dropped: {why}", c.ip));
            }
        }
    }

    fn on_readable(&mut self, id: u64) {
        let mut buf = std::mem::take(&mut self.rbuf);
        for _ in 0..8 {
            let n = match self.conns.get_mut(&id) {
                None => break,
                Some(c) => match c.stream.read(&mut buf) {
                    Ok(0) => {
                        self.drop_conn(id, true, "closed by the client");
                        break;
                    }
                    Ok(n) => {
                        c.last_read = Instant::now();
                        n
                    }
                    Err(e) if e.kind() == ErrorKind::WouldBlock => break,
                    Err(e) if e.kind() == ErrorKind::Interrupted => continue,
                    Err(e) => {
                        let why = format!("read error: {e}");
                        self.drop_conn(id, true, &why);
                        break;
                    }
                },
            };
            self.stats.bytes_in += n as u64;
            if let Err(why) = self.handle_bytes(id, &mut buf[..n]) {
                self.drop_conn(id, true, &why);
                break;
            }
            if n < buf.len() {
                break; // the socket is drained for now
            }
        }
        self.rbuf = buf;
    }

    fn handle_bytes(&mut self, id: u64, data: &mut [u8]) -> Result<(), String> {
        {
            let c = self.conns.get_mut(&id).ok_or("connection vanished")?;
            c.reader.feed(data).map_err(|e| e.0)?;
        }
        loop {
            let item = {
                let c = self.conns.get_mut(&id).ok_or("connection vanished")?;
                c.reader.next_item().map_err(|e| e.0)?
            };
            match item {
                None => return Ok(()),
                Some(Item::Frame(payload)) => {
                    if let Some(c) = self.conns.get_mut(&id) {
                        c.last_frame = Instant::now();
                    }
                    self.stats.frames_in += 1;
                    if let Some(u) = &self.urgent {
                        if frame_pid(&payload) == Some(u.chat) {
                            self.urgent_seen_chat = true;
                            if self.urgent_on {
                                self.urgent_want = true;
                            }
                        }
                    }
                    self.inbound.push((id, payload));
                }
                Some(Item::Key(body)) => self.handle_key(id, &body)?,
            }
        }
    }

    /// The frame that answers the encryption request: RSA-decrypt, check the challenge, switch to AES-128-CFB8 both ways, start the session check.
    /// Every failure is the same error (no distinction an attacker could use) and never reaches the session server.
    fn handle_key(&mut self, id: u64, body: &[u8]) -> Result<(), String> {
        let (ip, aw) = {
            let c = self.conns.get(&id).ok_or("connection vanished")?;
            (c.ip, c.reader.awaiting().cloned().ok_or("key frame without a request")?)
        };
        if !self.limits.login_allowed(ip, Instant::now()) {
            return Err("login attempt rate limit".into());
        }
        let (secret_ct, token_ct) = parse_key_packet(body, self.key_pkt).map_err(|e| format!("bad key packet: {e}"))?;
        let secret = self.rsa.decrypt(secret_ct).ok_or("bad key packet: shared secret")?;
        let secret: [u8; 16] = secret.try_into().map_err(|_| "bad key packet: shared secret length")?;
        let token = self.rsa.decrypt(token_ct).ok_or("bad key packet: verify token")?;
        if token != aw.token {
            return Err("bad key packet: verify token mismatch".into());
        }
        let enc = Cfb8Stream::new(&secret, true)?;
        let dec = Cfb8Stream::new(&secret, false)?;
        let hash = server_hash("", &secret, &self.pub_der);
        {
            let c = self.conns.get_mut(&id).ok_or("connection vanished")?;
            c.reader.accept_key(Box::new(dec)); // also decrypts the bytes already buffered behind the key frame
            c.enc = Some(enc);
        }
        self.begun.push(id);
        self.pool.submit(id, aw.name, hash);
        Ok(())
    }

    fn set_out_interest(&mut self, id: u64, want: bool) {
        if let Some(c) = self.conns.get_mut(&id) {
            if c.want_out != want {
                c.want_out = want;
                let ev = EPOLLIN | EPOLLRDHUP | if want { EPOLLOUT } else { 0 };
                let _ = self.ep.modify(c.stream.as_raw_fd(), ev, id);
            }
        }
    }

    /// Queues bytes for a socket (encrypting them when the connection is encrypted); a client whose queue exceeds the cap is disconnected.
    fn queue_out(&mut self, id: u64, mut data: Vec<u8>) {
        let cap = self.cfg.max_pending_bytes;
        let over = match self.conns.get_mut(&id) {
            None => return,
            Some(c) => {
                if let Some(e) = c.enc.as_mut() {
                    e.apply(&mut data);
                }
                if c.wq.is_empty() {
                    c.last_write = Instant::now();
                }
                c.wq.push(data) > cap
            }
        };
        if over {
            self.drop_conn(id, true, "write queue over the limit (the client cannot keep up)");
        }
    }

    fn flush(&mut self, id: u64) {
        loop {
            let res = match self.conns.get_mut(&id) {
                None => return,
                Some(c) => {
                    let front = c.wq.front();
                    if front.is_empty() {
                        None
                    } else {
                        Some(c.stream.write(front))
                    }
                }
            };
            match res {
                None => break,
                Some(Ok(0)) => {
                    self.drop_conn(id, true, "write returned 0");
                    return;
                }
                Some(Ok(n)) => {
                    if let Some(c) = self.conns.get_mut(&id) {
                        c.wq.consume(n);
                        c.last_write = Instant::now();
                    }
                    self.stats.bytes_out += n as u64;
                }
                Some(Err(e)) if e.kind() == ErrorKind::WouldBlock => {
                    self.set_out_interest(id, true);
                    return;
                }
                Some(Err(e)) if e.kind() == ErrorKind::Interrupted => continue,
                Some(Err(e)) => {
                    let why = format!("write error: {e}");
                    self.drop_conn(id, true, &why);
                    return;
                }
            }
        }
        self.set_out_interest(id, false);
        let close = self.conns.get(&id).map_or(false, |c| c.closing && c.wq.is_empty());
        if close {
            self.drop_conn(id, false, "closed after its last bytes (the database asked for it)");
        }
    }

    fn sweep_timeouts(&mut self) {
        let now = Instant::now();
        let limit = Duration::from_secs(self.cfg.read_timeout_s);
        let mut dead: Vec<(u64, &'static str)> = Vec::new();
        for (id, c) in self.conns.iter() {
            if now.duration_since(c.last_read) > limit {
                dead.push((*id, "read timeout (no bytes)"));
            } else if c.reader.buffered() > 0 && now.duration_since(c.last_frame) > limit {
                dead.push((*id, "read timeout (a frame never completed)"));
            } else if !c.wq.is_empty() && now.duration_since(c.last_write) > limit {
                dead.push((*id, "write timeout"));
            }
        }
        for (id, why) in dead {
            self.drop_conn(id, true, why);
        }
    }

    // ---- the tick ------------------------------------------------------------------------------------------------------------------------------------

    fn run_tick(&mut self, late: bool) {
        let t0 = Instant::now();
        self.urgent_runs = 0;
        self.verdicts.extend(self.pool.take());
        let mut inbound = std::mem::take(&mut self.inbound);
        let frames = inbound.len();
        if let (Some(ids), true) = (&self.urgent, self.urgent_on && self.urgent_seen_chat) {
            let conns = &self.conns;
            let fate = urgent_fate(&inbound, ids, &|cid| conns.get(&cid).map_or(false, |c| c.reader.in_play()));
            self.stats.chat_late += fate.takeable;
            self.stats.chat_blocked += fate.blocked_by_kind;
            self.stats.chat_behind_command += fate.behind_command;
            self.stats.chat_not_play += fate.not_play;
            for (pid, n) in fate.blockers {
                *self.chat_blockers.entry(pid).or_insert(0) += n;
            }
        }
        self.urgent_seen_chat = false;
        if self.cfg.skip_tick_end {
            if let Some(ids) = &self.urgent {
                let conns = &self.conns;
                drop_idle_tick_ends(&mut inbound, ids, &|cid| conns.get(&cid).map_or(false, |c| c.reader.in_play()));
            }
        }
        // nothing for the database but the tick itself (docs/PERF-IDLE.md): no transaction, no COPY, no apply/drain/control statements unless the probe says so
        let lean = self.cfg.lean_ticks && inbound.is_empty() && self.accepted.is_empty() && self.begun.is_empty() && self.dropped.is_empty() && self.verdicts.is_empty();
        let res = if lean { self.tick_lean(late, t0) } else { self.tick_db(&inbound, late, t0) };
        match res {
            Ok((out, db_ms)) => {
                self.accepted.clear();
                self.begun.clear();
                self.dropped.clear();
                self.verdicts.clear();
                self.apply_tick(out);
                if std::mem::take(&mut self.gens_wanted) {
                    if let Some(g) = &self.gens {
                        g.wake();
                    }
                }
                let ms = t0.elapsed().as_secs_f64() * 1000.0;
                if !self.cfg.tick_log.is_empty() && self.tick_samples.len() < 4_000_000 {
                    self.tick_samples.push((self.start.elapsed().as_millis() as u32, ms as f32, lean as u8 | ((late as u8) << 1)));
                }
                for s in [&mut self.stats, &mut self.stats_window] {
                    s.ticks += 1;
                    s.lean_ticks += lean as u64;
                    s.late += late as u64;
                    s.tick_ms_sum += ms;
                    s.tick_ms_max = s.tick_ms_max.max(ms);
                    s.db_ms_sum += db_ms;
                }
            }
            Err(e) => {
                // rolled back: this tick's inbound frames are dropped; accepted/begun/dropped/verdicts stay queued for the next tick
                self.stats.errors += 1;
                log(self.start, &format!("tick failed and was rolled back ({frames} inbound frames dropped): {e}"));
                if !self.db.is_ok() {
                    if self.db.reset() {
                        log(self.start, "database connection re-established");
                    }
                }
            }
        }
    }

    fn tick_db(&mut self, inbound: &[(u64, Vec<u8>)], late: bool, t0: Instant) -> Result<(TickOut, f64), PgError> {
        self.db.exec("begin")?;
        match self.tick_body(inbound, late, t0) {
            Ok(r) => {
                self.db.exec("commit")?;
                Ok(r)
            }
            Err(e) => {
                let _ = self.db.exec("rollback");
                Err(e)
            }
        }
    }

    fn tick_body(&mut self, inbound: &[(u64, Vec<u8>)], late: bool, t0: Instant) -> Result<(TickOut, f64), PgError> {
        let db_start = Instant::now();
        // 1. sockets accepted
        if !self.accepted.is_empty() {
            let ids: Vec<i64> = self.accepted.iter().map(|(i, _)| *i as i64).collect();
            let ips: Vec<&str> = self.accepted.iter().map(|(_, ip)| ip.as_str()).collect();
            let (a, b) = (pq::encode_array_i64(&ids), pq::encode_array_text(&ips));
            self.db.query(
                "select net.on_connect(c, i::inet) from unnest($1::bigint[], $2::text[]) as u(c, i)",
                &[Param::bin(pq::OID_INT8_ARRAY, &a), Param::bin(pq::OID_TEXT_ARRAY, &b)],
                false,
            )?;
        }
        // 2. inbound frames, only those of connections the database knows about or is about to know about (all of them: the socket may have closed since)
        if !inbound.is_empty() {
            if self.cfg.inbox_mode == "copy" {
                let rows: Vec<(i64, &[u8])> = inbound.iter().map(|(i, p)| (*i as i64, p.as_slice())).collect();
                let data = pq::encode_copy_i64_bytea(&rows);
                self.db.copy_in("copy net.inbox (conn_id, payload) from stdin (format binary)", &data)?;
            } else {
                let ids: Vec<i64> = inbound.iter().map(|(i, _)| *i as i64).collect();
                let payloads: Vec<&[u8]> = inbound.iter().map(|(_, p)| p.as_slice()).collect();
                let (a, b) = (pq::encode_array_i64(&ids), pq::encode_array_bytea(&payloads));
                self.db.query(
                    "insert into net.inbox (conn_id, payload) select c, p from unnest($1::bigint[], $2::bytea[]) as u(c, p)",
                    &[Param::bin(pq::OID_INT8_ARRAY, &a), Param::bin(pq::OID_BYTEA_ARRAY, &b)],
                    false,
                )?;
            }
        }
        // 3. key responses seen
        if !self.begun.is_empty() {
            let ids: Vec<i64> = self.begun.iter().map(|i| *i as i64).collect();
            let a = pq::encode_array_i64(&ids);
            self.db.query("select net.auth_begun($1::bigint[])", &[Param::bin(pq::OID_INT8_ARRAY, &a)], false)?;
        }
        // 4. session verdicts (of connections that still exist)
        for v in self.verdicts.iter().filter(|v| self.conns.contains_key(&v.conn_id)) {
            let id = v.conn_id.to_string();
            let sql = "insert into net.auth_result (conn_id, ok, reason, uuid, name, properties) values ($1::bigint, $2::boolean, $3::text, $4::uuid, $5::text, $6::jsonb)";
            match &v.outcome {
                Outcome::Ok { uuid, name, properties } => self.db.query(
                    sql,
                    &[Param::text(0, &id), Param::text(0, "t"), Param::null(0), Param::text(0, uuid), Param::text(0, name), Param::text(0, properties)],
                    false,
                )?,
                Outcome::Invalid | Outcome::Unavailable => {
                    let reason = if v.outcome == Outcome::Invalid { "invalid" } else { "unavailable" };
                    self.db.query(
                        sql,
                        &[Param::text(0, &id), Param::text(0, "f"), Param::text(0, reason), Param::null(0), Param::null(0), Param::text(0, "[]")],
                        false,
                    )?
                }
            };
        }
        self.db.exec("select net.apply_auth_results()")?;
        // 5. the game
        let tick_sql = format!("select {}", self.cfg.tick_fn);
        self.db.exec(&tick_sql)?;
        if self.gens.is_some() {
            let r = self.db.query("select exists (select 1 from mc.chunk_request)", &[], true)?;
            self.gens_wanted |= r.boolean(0, 0).unwrap_or(false);
        }
        // 6. sockets the client closed
        if !self.dropped.is_empty() {
            let ids: Vec<i64> = self.dropped.iter().map(|i| *i as i64).collect();
            let a = pq::encode_array_i64(&ids);
            self.db.query("select net.on_disconnect(c) from unnest($1::bigint[]) as u(c)", &[Param::bin(pq::OID_INT8_ARRAY, &a)], false)?;
        }
        // 7. the outbox
        let drain = self.read_drain()?;
        // 8. control rows
        let ctl = self.read_ctl()?;
        let db_ms = db_start.elapsed().as_secs_f64() * 1000.0;
        // 9. statistics and the stop flag of the control table (present when the development gateway's SQL is installed)
        let mut stop = false;
        if self.has_control {
            let ms = t0.elapsed().as_secs_f64() * 1000.0;
            self.note_tick(ms, late);
            stop = self.control_update(ms)?;
        }
        Ok((TickOut { drain, ctl, stop }, db_ms))
    }

    fn note_tick(&mut self, ms: f64, late: bool) {
        let p = &mut self.lean_pending;
        p.0 += 1;
        p.1 += late as u32;
        p.2 = p.2.max(ms);
        p.3 = ms;
    }

    /// Writes the control row (statistics of the development gateway's table and the stop flag), counting the lean ticks since the last write too.  Returns the stop flag.
    fn control_update(&mut self, ms: f64) -> Result<bool, PgError> {
        let (n, l, mx, _) = self.lean_pending;
        let ticks = (n as i32).to_be_bytes();
        let ms_last = ms.to_be_bytes();
        let ms_max = mx.to_be_bytes();
        let late_i = (l as i32).to_be_bytes();
        let conns = (self.conns.len() as i32).to_be_bytes();
        let r = self.db.query(
            "update net.gateway_control set ticks = ticks + $4, last_tick_ms = $1, max_tick_ms = greatest(coalesce(max_tick_ms, 0), $5), late_ticks = late_ticks + $2, connections = $3 returning stop",
            &[
                Param::bin(pq::OID_FLOAT8, &ms_last),
                Param::bin(pq::OID_INT4, &late_i),
                Param::bin(pq::OID_INT4, &conns),
                Param::bin(pq::OID_INT4, &ticks),
                Param::bin(pq::OID_FLOAT8, &ms_max),
            ],
            true,
        )?;
        self.lean_pending = (0, 0, 0.0, 0.0);
        Ok(r.boolean(0, 0).unwrap_or(false))
    }

    /// The tick when the gateway has nothing to give the database: the tick function (its own transaction), then one probe; the outbox is drained and the control rows
    /// are read only when the probe says there is something.  The control row is written every 20th lean tick (the stop flag is looked at then: a stop request is acted on within 1 s).
    fn tick_lean(&mut self, late: bool, t0: Instant) -> Result<(TickOut, f64), PgError> {
        let db_start = Instant::now();
        // one prepared statement, one round trip: the tick and the probe (docs/PERF-IDLE2.md).  The probe runs after the tick in the same transaction and sees its writes.
        self.db.prepare(LEAN_STMT, &self.lean_sql, &[pq::OID_INT8])?;
        let after = self.last_ctl.to_be_bytes();
        let r = self.db.query_prepared(LEAN_STMT, &[Param::bin(pq::OID_INT8, &after)], true)?;
        let pending = r.int(0, 1).unwrap_or(3);
        drop(r);
        if pending & 4 != 0 {
            self.gens_wanted = true;
        }
        let mut drain = Vec::new();
        let mut ctl = Vec::new();
        if pending & 1 != 0 {
            drain = self.read_drain()?;
        }
        if pending & 2 != 0 {
            ctl = self.read_ctl()?;
        }
        let db_ms = db_start.elapsed().as_secs_f64() * 1000.0;
        let ms = t0.elapsed().as_secs_f64() * 1000.0;
        let mut stop = false;
        if self.has_control {
            self.note_tick(ms, late);
            if self.lean_pending.0 >= LEAN_CONTROL_EVERY || pending != 0 {
                stop = self.control_update(ms)?;
            }
        }
        Ok((TickOut { drain, ctl, stop }, db_ms))
    }

    fn read_drain(&mut self) -> Result<Vec<DrainRow>, PgError> {
        let r = self.db.query("select conn_id, data, close from net.drain_outbox()", &[], true)?;
        let mut drain = Vec::with_capacity(r.rows());
        for i in 0..r.rows() {
            let conn_id = r.int(i, 0).unwrap_or(-1);
            if conn_id < 0 {
                continue;
            }
            drain.push(DrainRow { conn_id: conn_id as u64, data: r.bytes(i, 1).map(|b| b.to_vec()).unwrap_or_default(), close: r.boolean(i, 2).unwrap_or(false) });
        }
        Ok(drain)
    }

    fn read_ctl(&mut self) -> Result<Vec<CtlRow>, PgError> {
        let after = self.last_ctl.to_be_bytes();
        let r = self.db.query(
            "select conn_id, ctl_seq, state, compression, await_key, name, verify_token from net.gateway_ctl($1)",
            &[Param::bin(pq::OID_INT8, &after)],
            true,
        )?;
        let mut ctl = Vec::with_capacity(r.rows());
        for i in 0..r.rows() {
            let (conn_id, seq) = match (r.int(i, 0), r.int(i, 1)) {
                (Some(a), Some(b)) if a >= 0 => (a as u64, b),
                _ => continue,
            };
            let await_key = if r.boolean(i, 4).unwrap_or(false) {
                match (r.bytes(i, 6), r.text(i, 5)) {
                    (Some(t), Some(n)) => Some(Await { token: t.to_vec(), name: n }),
                    _ => None,
                }
            } else {
                None
            };
            ctl.push(CtlRow { conn_id, seq, state: r.text(i, 2).unwrap_or_default(), compression: r.int(i, 3).map(|v| v as i32), await_key });
        }
        Ok(ctl)
    }

    /// The urgent chat lane: chat frames that arrived since the last tick are handled now (net.urgent_chat, then the outbox is drained, one transaction) when the next
    /// tick is far enough away.  The frames it takes leave `inbound`; the others, and everything when the run fails, wait for the tick as before.
    fn run_urgent(&mut self, sched: Instant) {
        let ids = match &self.urgent {
            Some(u) if self.urgent_on => u.clone(),
            _ => return,
        };
        if self.urgent_runs >= self.cfg.urgent_max_per_tick {
            return;
        }
        let now = Instant::now();
        let reserve = Duration::from_secs_f64((self.urgent_cost_ms + self.cfg.urgent_reserve_ms as f64) / 1000.0);
        if now < sched && now + reserve > sched {
            return; // the tick is due soon: it takes the frames
        }
        // (docs/PERF-STORM.md) a tick that is already overdue (the previous one ran long, a login storm) is not a reason to leave the chat waiting for the next one: the lane runs
        // before the late tick starts, at most urgent_max_per_tick times, and costs the tick 2-3 ms; without this the lane never ran while ticks were longer than 50 ms.
        let taken = {
            let conns = &self.conns;
            urgent_candidates(&self.inbound, &ids, &|cid| conns.get(&cid).map_or(false, |c| c.reader.in_play()))
        };
        if taken.is_empty() {
            return;
        }
        let t = Instant::now();
        match self.urgent_db(&taken) {
            Ok((drain, unhandled)) => {
                let handled: HashSet<usize> = taken.iter().enumerate().filter(|(k, _)| !unhandled.contains(&(*k as i64 + 1))).map(|(_, i)| *i).collect();
                let mut i = 0usize;
                self.inbound.retain(|_| {
                    let keep = !handled.contains(&i);
                    i += 1;
                    keep
                });
                self.urgent_runs += 1;
                let ms = t.elapsed().as_secs_f64() * 1000.0;
                self.urgent_cost_ms = 0.7 * self.urgent_cost_ms + 0.3 * ms;
                for s in [&mut self.stats, &mut self.stats_window] {
                    s.urgent_runs += 1;
                    s.urgent_frames += handled.len() as u64;
                }
                self.apply_tick(TickOut { drain, ctl: Vec::new(), stop: false });
            }
            Err(e) => {
                self.stats.errors += 1;
                self.urgent_runs = self.cfg.urgent_max_per_tick; // no more tries before the next tick: the tick takes the frames
                log(self.start, &format!("urgent chat run failed and was rolled back: {e}"));
                if !self.db.is_ok() {
                    if self.db.reset() {
                        log(self.start, "database connection re-established");
                    }
                }
            }
        }
    }

    fn urgent_db(&mut self, taken: &[usize]) -> Result<(Vec<DrainRow>, Vec<i64>), PgError> {
        self.db.exec("begin")?;
        let r = (|| -> Result<(Vec<DrainRow>, Vec<i64>), PgError> {
            let ids: Vec<i64> = taken.iter().map(|i| self.inbound[*i].0 as i64).collect();
            let payloads: Vec<&[u8]> = taken.iter().map(|i| self.inbound[*i].1.as_slice()).collect();
            let (a, b) = (pq::encode_array_i64(&ids), pq::encode_array_bytea(&payloads));
            let res = self.db.query(
                "select coalesce(array_to_string(net.urgent_chat($1::bigint[], $2::bytea[]), ','), '')",
                &[Param::bin(pq::OID_INT8_ARRAY, &a), Param::bin(pq::OID_BYTEA_ARRAY, &b)],
                false,
            )?;
            let unhandled: Vec<i64> = res.text(0, 0).unwrap_or_default().split(',').filter_map(|x| x.trim().parse().ok()).collect();
            drop(res);
            let drain = self.read_drain()?;
            Ok((drain, unhandled))
        })();
        match r {
            Ok(v) => {
                self.db.exec("commit")?;
                Ok(v)
            }
            Err(e) => {
                let _ = self.db.exec("rollback");
                Err(e)
            }
        }
    }

    fn apply_tick(&mut self, out: TickOut) {
        if out.stop {
            log(self.start, "stop requested through net.gateway_control");
            self.stop = true;
        }
        let mut with_data: Vec<u64> = Vec::new();
        for row in out.drain {
            if !self.conns.contains_key(&row.conn_id) {
                continue;
            }
            if !row.data.is_empty() {
                self.stats.frames_out += 1;
                self.queue_out(row.conn_id, row.data);
                with_data.push(row.conn_id);
            }
            if row.close {
                if let Some(c) = self.conns.get_mut(&row.conn_id) {
                    c.closing = true;
                }
                with_data.push(row.conn_id);
            }
        }
        for row in out.ctl {
            self.last_ctl = self.last_ctl.max(row.seq);
            if let Some(c) = self.conns.get_mut(&row.conn_id) {
                c.reader.control(row.compression, &row.state, row.await_key);
            }
        }
        for id in with_data {
            self.flush(id);
        }
    }

    fn flush_stats(&mut self) {
        let w = std::mem::take(&mut self.stats_window);
        let (cur, prev) = (self.stats.clone(), self.reported.clone());
        self.reported = cur.clone();
        if w.ticks == 0 && cur.errors == prev.errors {
            return;
        }
        let ticks = w.ticks.max(1) as f64;
        let vals: Vec<String> = vec![
            w.ticks.to_string(),
            w.late.to_string(),
            format!("{}", w.tick_ms_sum / ticks),
            format!("{}", w.tick_ms_max),
            format!("{}", w.db_ms_sum / ticks),
            (cur.frames_in - prev.frames_in).to_string(),
            (cur.bytes_in - prev.bytes_in).to_string(),
            (cur.frames_out - prev.frames_out).to_string(),
            (cur.bytes_out - prev.bytes_out).to_string(),
            self.conns.len().to_string(),
            (cur.rejected - prev.rejected).to_string(),
            (cur.errors - prev.errors).to_string(),
        ];
        let _ = (w.lean_ticks, w.urgent_runs, w.urgent_frames); // reported in the log line below (the statistics table has no column for them)
        let params: Vec<Param> = vals.iter().map(|v| Param::text(0, v)).collect();
        let sql = "insert into net.gateway_stats (ticks, late_ticks, tick_ms_avg, tick_ms_max, db_ms_avg, frames_in, bytes_in, frames_out, bytes_out, connections, rejected, errors) \
                   values ($1::int, $2::int, $3::float8, $4::float8, $5::float8, $6::bigint, $7::bigint, $8::bigint, $9::bigint, $10::int, $11::int, $12::int) on conflict (ts) do nothing";
        if let Err(e) = self.db.query(sql, &params, false) {
            log(self.start, &format!("statistics row failed: {e}"));
        }
    }

    fn shutdown(&mut self) {
        // tell the database about every connection that is going away (the next start would clean them anyway)
        let ids: Vec<i64> = self.conns.keys().map(|i| *i as i64).chain(self.dropped.iter().map(|i| *i as i64)).collect();
        if !ids.is_empty() && self.db.exec("begin").is_ok() {
            let a = pq::encode_array_i64(&ids);
            let _ = self.db.query("select net.on_disconnect(c) from unnest($1::bigint[]) as u(c)", &[Param::bin(pq::OID_INT8_ARRAY, &a)], false);
            let _ = self.db.exec("commit");
        }
        let all: Vec<u64> = self.conns.keys().copied().collect();
        for id in all {
            self.drop_conn(id, false, "");
        }
        if !self.cfg.tick_log.is_empty() {
            let mut text = String::with_capacity(self.tick_samples.len() * 20);
            for (t, ms, fl) in &self.tick_samples {
                text.push_str(&format!("{t},{ms:.3},{fl}\n"));
            }
            match std::fs::write(&self.cfg.tick_log, text) {
                Ok(()) => log(self.start, &format!("{} tick durations written to {}", self.tick_samples.len(), self.cfg.tick_log)),
                Err(e) => log(self.start, &format!("cannot write {}: {e}", self.cfg.tick_log)),
            }
        }
        if let Some(g) = self.gens.take() {
            let (runs, errors) = g.stop();
            log(self.start, &format!("generator threads stopped after {runs} calls, {errors} errors"));
        }
        if let Some(m) = self.maint.take() {
            let (passes, errors) = m.stop();
            log(self.start, &format!("maintenance thread stopped after {passes} vacuum passes, {errors} errors"));
        }
        let mut blockers: Vec<(u32, u64)> = self.chat_blockers.iter().map(|(k, v)| (*k, *v)).collect();
        blockers.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
        let blockers: Vec<String> = blockers.iter().take(8).map(|(k, v)| format!("{k}:{v}")).collect();
        log(
            self.start,
            &format!(
                "stopped ({} ticks, {} lean, {} late; urgent chat: {} runs took {} frames, {} chat frames went to the tick: {} takeable but late, {} behind another frame of their connection (packet id:count {}), {} behind a command, {} not in play; {} errors)",
                self.stats.ticks, self.stats.lean_ticks, self.stats.late, self.stats.urgent_runs, self.stats.urgent_frames, self.stats.chat_late + self.stats.chat_blocked + self.stats.chat_behind_command + self.stats.chat_not_play,
                self.stats.chat_late, self.stats.chat_blocked, blockers.join(","), self.stats.chat_behind_command, self.stats.chat_not_play, self.stats.errors
            ),
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ids() -> UrgentIds {
        UrgentIds { chat: 7, cmd: [6, 5], tick_end: 12, pos: 30, pos_rot: 31, neutral: vec![12, 28, 29, 30, 31, 43, 46] }
    }

    fn f(conn: u64, pid: u8) -> (u64, Vec<u8>) {
        (conn, vec![pid, 1, 2, 3])
    }

    fn play(_: u64) -> bool {
        true
    }

    #[test]
    fn packet_ids_are_read_from_the_first_varint() {
        assert_eq!(frame_pid(&[7, 9]), Some(7));
        assert_eq!(frame_pid(&[0x81, 0x01]), Some(129));
        assert_eq!(frame_pid(&[]), None);
        assert_eq!(frame_pid(&[0x80, 0x80, 0x80, 0x80]), None);
    }

    #[test]
    fn tick_end_frames_are_dropped_unless_the_connection_sent_two_positions() {
        // ids: tick_end 12, pos 30, pos_rot 31
        let mut frames = vec![f(1, 12), f(2, 30), f(2, 12), f(3, 30), f(3, 31), f(3, 12), f(4, 12), f(5, 7)];
        drop_idle_tick_ends(&mut frames, &ids(), &|c| c != 4);
        let kept: Vec<(u64, u8)> = frames.iter().map(|(c, p)| (*c, p[0])).collect();
        // connection 1: only a tick_end: dropped; 2: one position: its tick_end dropped; 3: two positions: kept; 4 is not in play: kept; chat untouched
        assert_eq!(kept, vec![(2, 30), (3, 30), (3, 31), (3, 12), (4, 12), (5, 7)]);
    }

    #[test]
    fn chat_after_neutral_frames_of_its_own_connection_is_urgent() {
        let frames = vec![f(1, 12), f(1, 30), f(1, 7), f(2, 7)];
        assert_eq!(urgent_candidates(&frames, &ids(), &play), vec![2, 3]);
    }

    #[test]
    fn a_frame_of_another_kind_ahead_of_a_chat_blocks_that_connection_only() {
        // connection 1 sent a block action (id 44) before its chat; connection 2's chat is unaffected
        let frames = vec![f(1, 44), f(1, 7), f(2, 7), f(1, 7)];
        assert_eq!(urgent_candidates(&frames, &ids(), &play), vec![2]);
    }

    #[test]
    fn a_command_stops_everything_behind_it_whoever_sent_it() {
        let frames = vec![f(1, 7), f(2, 6), f(3, 7), f(1, 7)];
        assert_eq!(urgent_candidates(&frames, &ids(), &play), vec![0]);
        let frames = vec![f(2, 5), f(1, 7)];
        assert!(urgent_candidates(&frames, &ids(), &play).is_empty());
    }

    #[test]
    fn kinds_the_database_declares_neutral_do_not_hold_a_chat_back() {
        // 43 = player_input, 46 = punch (swing) in this test's id table: a real client sends them ahead of its chat; 44 is a block action
        let frames = vec![f(1, 12), f(1, 43), f(1, 46), f(1, 7), f(2, 43), f(2, 7), f(3, 44), f(3, 7)];
        assert_eq!(urgent_candidates(&frames, &ids(), &play), vec![3, 5]);
    }

    #[test]
    fn chat_stays_in_order_with_chat_and_commands_whatever_stood_ahead() {
        // neutral frames never change the two orders that matter: a command of any connection stops everything behind it, and a chat that was not taken holds back the next of its connection
        let frames = vec![f(1, 43), f(1, 7), f(2, 46), f(2, 6), f(3, 43), f(3, 7)];
        assert_eq!(urgent_candidates(&frames, &ids(), &play), vec![1]);
        let not_one = |c: u64| c != 1;
        let frames = vec![f(1, 43), f(1, 7), f(1, 46), f(1, 7)];
        assert!(urgent_candidates(&frames, &ids(), &not_one).is_empty());
    }

    #[test]
    fn fate_of_chat_frames_the_tick_is_left_with() {
        let not_three = |c: u64| c != 3;
        // 1: takeable (late: the lane did not run); 2: a block action (44) ahead; 3: not in play; 4: behind a command of 5; 2's second chat is behind its first (not takeable): counted with 44
        let frames = vec![f(1, 43), f(1, 7), f(2, 44), f(2, 7), f(2, 7), f(3, 7), f(5, 6), f(4, 7)];
        let fate = urgent_fate(&frames, &ids(), &not_three);
        assert_eq!((fate.takeable, fate.blocked_by_kind, fate.behind_command, fate.not_play), (1, 2, 1, 1));
        assert_eq!(fate.blockers.get(&44), Some(&2));
        // a frame whose id cannot be read blocks its connection
        let frames = vec![(9u64, vec![0x80, 0x80, 0x80, 0x80]), f(9, 7)];
        let fate = urgent_fate(&frames, &ids(), &play);
        assert_eq!((fate.takeable, fate.blocked_by_kind), (0, 1));
    }

    #[test]
    fn only_play_connections_are_candidates_and_a_refused_chat_blocks_the_next() {
        let not_one = |c: u64| c != 1;
        let frames = vec![f(1, 7), f(1, 7), f(2, 7)];
        assert_eq!(urgent_candidates(&frames, &ids(), &not_one), vec![2]);
    }
}
