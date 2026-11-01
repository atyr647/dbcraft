//! The gateway: one thread, one epoll loop, sockets from `std`, the database through libpq.  Behaves exactly like the reference gateway written as database code
//! (sql/optional/dev_gateway_online.sql) as seen from SQL: per tick, in ONE transaction and in this order:
//!   net.on_connect for sockets accepted -> inbound frames into net.inbox -> net.auth_begun -> session verdicts into net.auth_result -> net.apply_auth_results()
//!   -> the server tick -> net.on_disconnect for sockets the client closed -> net.drain_outbox() -> net.gateway_ctl() -> statistics.
//! After the commit the drained bytes are queued per socket (encrypted when the connection is), control rows are applied, and sockets are written.
//! If the transaction fails it is rolled back; the tick's inbound frames are dropped (a poison frame must not stall the server), everything else is retried next tick.

use crate::config::Config;
use crate::ffi::ossl::{Cfb8Stream, RsaKey};
use crate::ffi::pq::{self, Param, Pg, PgError};
use crate::ffi::sys::{self, Epoll, EventFd, EPOLLERR, EPOLLHUP, EPOLLIN, EPOLLOUT, EPOLLRDHUP};
use crate::keypkt::parse_key_packet;
use crate::limits::{LimitConfig, Limits};
use crate::mojang::{Outcome, PoolConfig, SessionPool, Verdict};
use crate::reader::{Await, Item, Reader, ReaderLimits};
use crate::wq::WriteQueue;
use dbcraft_gateway_core::hash::server_hash;
use std::collections::HashMap;
use std::io::{ErrorKind, Read, Write};
use std::net::{IpAddr, Shutdown, TcpListener, TcpStream};
use std::os::fd::AsRawFd;
use std::sync::Arc;
use std::time::{Duration, Instant};

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
        let limits = Limits::new(LimitConfig {
            max_connections: cfg.max_connections,
            max_per_ip: cfg.max_connections_per_ip,
            new_per_ip_per_sec: cfg.new_connections_per_ip_per_sec,
            logins_per_ip_per_min: cfg.login_attempts_per_ip_per_min,
        });
        log(
            start,
            &format!(
                "listening on {} (tick {} ms, {}, inbox via {}, session server {}, {} stale connections cleaned)",
                cfg.listen, cfg.tick_ms, cfg.tick_fn, cfg.inbox_mode, cfg.session_url, cleaned
            ),
        );
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
        self.verdicts.extend(self.pool.take());
        let inbound = std::mem::take(&mut self.inbound);
        let frames = inbound.len();
        match self.tick_db(&inbound, late, t0) {
            Ok((out, db_ms)) => {
                self.accepted.clear();
                self.begun.clear();
                self.dropped.clear();
                self.verdicts.clear();
                self.apply_tick(out);
                let ms = t0.elapsed().as_secs_f64() * 1000.0;
                for s in [&mut self.stats, &mut self.stats_window] {
                    s.ticks += 1;
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
        // 6. sockets the client closed
        if !self.dropped.is_empty() {
            let ids: Vec<i64> = self.dropped.iter().map(|i| *i as i64).collect();
            let a = pq::encode_array_i64(&ids);
            self.db.query("select net.on_disconnect(c) from unnest($1::bigint[]) as u(c)", &[Param::bin(pq::OID_INT8_ARRAY, &a)], false)?;
        }
        // 7. the outbox
        let r = self.db.query("select conn_id, data, close from net.drain_outbox()", &[], true)?;
        let mut drain = Vec::with_capacity(r.rows());
        for i in 0..r.rows() {
            let conn_id = r.int(i, 0).unwrap_or(-1);
            if conn_id < 0 {
                continue;
            }
            drain.push(DrainRow { conn_id: conn_id as u64, data: r.bytes(i, 1).map(|b| b.to_vec()).unwrap_or_default(), close: r.boolean(i, 2).unwrap_or(false) });
        }
        drop(r);
        // 8. control rows
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
        drop(r);
        let db_ms = db_start.elapsed().as_secs_f64() * 1000.0;
        // 9. statistics and the stop flag of the control table (present when the development gateway's SQL is installed)
        let mut stop = false;
        if self.has_control {
            let ms = (t0.elapsed().as_secs_f64() * 1000.0).to_be_bytes();
            let late_i = (late as i32).to_be_bytes();
            let conns = (self.conns.len() as i32).to_be_bytes();
            let r = self.db.query(
                "update net.gateway_control set ticks = ticks + 1, last_tick_ms = $1, max_tick_ms = greatest(coalesce(max_tick_ms, 0), $1), late_ticks = late_ticks + $2, connections = $3 returning stop",
                &[Param::bin(pq::OID_FLOAT8, &ms), Param::bin(pq::OID_INT4, &late_i), Param::bin(pq::OID_INT4, &conns)],
                true,
            )?;
            stop = r.boolean(0, 0).unwrap_or(false);
        }
        Ok((TickOut { drain, ctl, stop }, db_ms))
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
        log(self.start, "stopped");
    }
}
