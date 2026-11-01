//! One reader task and one writer task per connection.  The reader decrypts (once online-mode encryption has started), cuts frames with adacraft's
//! rules, inflates them if the connection's compression is on, and hands them to the tick; the ONE frame it interprets is the answer to an encryption request.
//! The writer encrypts what the tick sends and enforces the write timeout.  Neither knows a packet layout beyond that one frame.
//!
//! STATUS: written against the verified `dbcraft-gateway-core` and the contract the reference gateway (sql/optional/dev_gateway_online.sql) proves; this file
//! has never been through a compiler (see docs/GATEWAY.md): the first `cargo build` is expected to need small fixes.

use crate::config::Config;
use crate::mojang::{AuthError, Profile, SessionClient};
use crate::serverkey::ServerKey;
// the same interface twice: AES-NI blocks (feature "aesni", the default) or the verified std-only reference cipher
#[cfg(feature = "aesni")]
use crate::cipher::Cfb8;
#[cfg(not(feature = "aesni"))]
use dbcraft_gateway_core::aes::Cfb8;
use dbcraft_gateway_core::frame::{inflate_frame, read_varint, FrameSplitter, MAX_FRAME};
use dbcraft_gateway_core::hash::server_hash;
use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::tcp::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::TcpStream;
use tokio::sync::{mpsc, watch};

/// What the tick needs to know about the outside world.
pub enum Event {
    Connected { id: u64, ip: String, handle: ConnHandle },
    Frames { id: u64, frames: Vec<Vec<u8>> },
    /// The key response was valid and encryption has started on this socket: the database moves the connection to "authenticating".
    KeyAccepted { id: u64 },
    Verdict { id: u64, result: Result<Profile, AuthError> },
    /// The socket is gone.  `by_client`: it ended on its side (EOF, error, timeout, bad frame), so the database must be told; false when we closed it.
    Closed { id: u64, by_client: bool },
}

pub enum Out {
    Data(Vec<u8>),
    Close,
}

/// A pending encryption request: the next complete frame of the connection answers it.
pub struct Await {
    pub token: Vec<u8>,
    pub name: String,
}

pub struct Shared {
    /// Compression threshold in effect for INBOUND frames (-1 = off); set from the database's control channel.
    pub compression: AtomicI32,
    /// true once the connection is in the play state (lifts the small pre-login frame limit).
    pub play: AtomicBool,
    pub awaiting: Mutex<Option<Await>>,
    /// Set by the reader when encryption starts; the writer picks it up before its next write.
    pub enc_key: Mutex<Option<[u8; 16]>>,
    /// Bytes queued for the writer and not yet written (backpressure).
    pub pending: AtomicUsize,
    pub kill: watch::Sender<bool>,
}

#[derive(Clone)]
pub struct ConnHandle {
    pub shared: Arc<Shared>,
    pub tx: mpsc::Sender<Out>,
}

/// Per-address limits: concurrent connections, new connections per second, login (key response) attempts per minute.
pub struct Limits {
    per_ip: HashMap<String, usize>,
    recent: HashMap<String, VecDeque<Instant>>,
    logins: HashMap<String, VecDeque<Instant>>,
    total: usize,
}

impl Limits {
    pub fn new() -> Limits {
        Limits { per_ip: HashMap::new(), recent: HashMap::new(), logins: HashMap::new(), total: 0 }
    }
    pub fn connect(&mut self, ip: &str, cfg: &Config) -> bool {
        if self.total >= cfg.max_connections {
            return false;
        }
        if cfg.max_connections_per_ip > 0 && self.per_ip.get(ip).copied().unwrap_or(0) >= cfg.max_connections_per_ip {
            return false;
        }
        if cfg.new_connections_per_ip_per_sec > 0 {
            let q = self.recent.entry(ip.to_string()).or_default();
            let now = Instant::now();
            while q.front().map_or(false, |t| now.duration_since(*t) > Duration::from_secs(1)) {
                q.pop_front();
            }
            if q.len() as u32 >= cfg.new_connections_per_ip_per_sec {
                return false;
            }
            q.push_back(now);
        }
        *self.per_ip.entry(ip.to_string()).or_insert(0) += 1;
        self.total += 1;
        true
    }
    pub fn disconnect(&mut self, ip: &str) {
        if let Some(n) = self.per_ip.get_mut(ip) {
            *n -= 1;
            if *n == 0 {
                self.per_ip.remove(ip);
            }
        }
        self.total = self.total.saturating_sub(1);
    }
    pub fn login_allowed(&mut self, ip: &str, cfg: &Config) -> bool {
        if cfg.login_attempts_per_ip_per_min == 0 {
            return true;
        }
        let q = self.logins.entry(ip.to_string()).or_default();
        let now = Instant::now();
        while q.front().map_or(false, |t| now.duration_since(*t) > Duration::from_secs(60)) {
            q.pop_front();
        }
        if q.len() as u32 >= cfg.login_attempts_per_ip_per_min {
            return false;
        }
        q.push_back(now);
        true
    }
    /// Forget idle addresses (called once a minute).
    pub fn sweep(&mut self) {
        let now = Instant::now();
        self.recent.retain(|_, q| q.back().map_or(false, |t| now.duration_since(*t) < Duration::from_secs(2)));
        self.logins.retain(|_, q| q.back().map_or(false, |t| now.duration_since(*t) < Duration::from_secs(61)));
    }
}

pub struct Ctx {
    pub cfg: Config,
    pub key: ServerKey,
    /// id of the serverbound login `key` packet (read from ref.packet at start)
    pub key_pkt_id: u32,
    pub session: SessionClient,
    pub limits: Mutex<Limits>,
}

fn read_bytes_field(b: &[u8], pos: usize, cap: usize) -> Result<(&[u8], usize), &'static str> {
    let (n, used) = match read_varint(&b[pos..]) {
        Ok(Some(x)) => x,
        _ => return Err("bad byte array length"),
    };
    let (n, start) = (n as usize, pos + used);
    if n > cap || start + n > b.len() {
        return Err("byte array out of range");
    }
    Ok((&b[start..start + n], start + n))
}

/// The answer to an encryption request: `[VarInt packet id][byte[] RSA(secret)][byte[] RSA(challenge)]`.  Returns the 16-byte shared secret.
pub fn parse_key_response(frame: &[u8], key_pkt_id: u32, key: &ServerKey, expected_token: &[u8]) -> Result<[u8; 16], &'static str> {
    let (pid, used) = match read_varint(frame) {
        Ok(Some(x)) => x,
        _ => return Err("no packet id"),
    };
    if pid != key_pkt_id {
        return Err("expected the key packet");
    }
    let (keybytes, pos) = read_bytes_field(frame, used, 512)?;
    let (chall, pos) = read_bytes_field(frame, pos, 512)?;
    if pos != frame.len() {
        return Err("trailing bytes after the key packet");
    }
    let secret = key.decrypt(keybytes).map_err(|_| "cannot decrypt the shared secret")?;
    let secret: [u8; 16] = secret.as_slice().try_into().map_err(|_| "shared secret is not 16 bytes")?;
    let token = key.decrypt(chall).map_err(|_| "cannot decrypt the challenge")?;
    if token != expected_token {
        return Err("verify token mismatch");
    }
    Ok(secret)
}

/// Starts the two tasks of a connection and returns its handle.
pub fn spawn_connection(stream: TcpStream, id: u64, ip: String, ctx: Arc<Ctx>, ev: mpsc::Sender<Event>) -> ConnHandle {
    let _ = stream.set_nodelay(true);
    let (rd, wr) = stream.into_split();
    let (kill_tx, kill_rx) = watch::channel(false);
    let (tx, rx) = mpsc::channel::<Out>(1024);
    let shared = Arc::new(Shared {
        compression: AtomicI32::new(-1),
        play: AtomicBool::new(false),
        awaiting: Mutex::new(None),
        enc_key: Mutex::new(None),
        pending: AtomicUsize::new(0),
        kill: kill_tx,
    });
    tokio::spawn(reader(rd, id, ip, shared.clone(), ctx.clone(), ev, kill_rx.clone()));
    tokio::spawn(writer(wr, shared.clone(), rx, kill_rx, Duration::from_secs(ctx.cfg.write_timeout_s)));
    ConnHandle { shared, tx }
}

async fn reader(mut rd: OwnedReadHalf, id: u64, ip: String, shared: Arc<Shared>, ctx: Arc<Ctx>, ev: mpsc::Sender<Event>, mut kill: watch::Receiver<bool>) {
    let mut split = FrameSplitter::new();
    let mut dec: Option<Cfb8> = None;
    let mut buf = vec![0u8; 16 * 1024];
    let mut prelogin_bytes = 0usize;
    let read_timeout = Duration::from_secs(ctx.cfg.read_timeout_s);
    let by_client = loop {
        let n = tokio::select! {
            _ = kill.changed() => break false,
            r = tokio::time::timeout(read_timeout, rd.read(&mut buf)) => match r {
                Err(_) => break true,          // idle or stalled in the middle of a frame: vanilla's 30 s read timeout
                Ok(Ok(0)) => break true,
                Ok(Ok(n)) => n,
                Ok(Err(_)) => break true,
            },
        };
        if let Some(d) = dec.as_mut() {
            d.decrypt(&mut buf[..n]);
        }
        if !shared.play.load(Ordering::Relaxed) {
            prelogin_bytes += n;
            if prelogin_bytes > ctx.cfg.prelogin_max_bytes {
                break true;
            }
        }
        split.push(&buf[..n]);
        let mut frames: Vec<Vec<u8>> = Vec::new();
        let mut failed = false;
        loop {
            let max = if shared.play.load(Ordering::Relaxed) { MAX_FRAME } else { ctx.cfg.prelogin_max_frame };
            match split.next(max) {
                Ok(Some(frame)) => {
                    let waiting = shared.awaiting.lock().unwrap().take();
                    if let Some(aw) = waiting {
                        // online mode: this frame answers our encryption request
                        let allowed = ctx.limits.lock().unwrap().login_allowed(&ip, &ctx.cfg);
                        let secret = if allowed { parse_key_response(&frame, ctx.key_pkt_id, &ctx.key, &aw.token) } else { Err("too many login attempts") };
                        match secret {
                            Ok(secret) => {
                                dec = Some(Cfb8::new(&secret));
                                dec.as_mut().unwrap().decrypt(split.buffer_mut()); // bytes already buffered behind the key frame are ciphertext
                                *shared.enc_key.lock().unwrap() = Some(secret);
                                let hash = server_hash("", &secret, &ctx.key.public_der);
                                let (ctx2, ev2, name) = (ctx.clone(), ev.clone(), aw.name.clone());
                                tokio::spawn(async move {
                                    let result = ctx2.session.has_joined(&name, &hash).await;
                                    let _ = ev2.send(Event::Verdict { id, result }).await;
                                });
                                if ev.send(Event::KeyAccepted { id }).await.is_err() {
                                    failed = true;
                                    break;
                                }
                            }
                            Err(why) => {
                                log::debug!("connection {id} ({ip}): {why}");
                                failed = true;
                                break;
                            }
                        }
                        continue;
                    }
                    let thr = shared.compression.load(Ordering::Relaxed);
                    if thr >= 0 {
                        match inflate_frame(&frame, thr as usize) {
                            Ok(f) => frames.push(f),
                            Err(e) => {
                                log::debug!("connection {id} ({ip}): {e}");
                                failed = true;
                                break;
                            }
                        }
                    } else {
                        frames.push(frame);
                    }
                }
                Ok(None) => break,
                Err(e) => {
                    log::debug!("connection {id} ({ip}): {e}");
                    failed = true;
                    break;
                }
            }
        }
        if !frames.is_empty() && ev.send(Event::Frames { id, frames }).await.is_err() {
            break false;
        }
        if failed {
            break true;
        }
    };
    let _ = shared.kill.send(true); // stops the writer
    ctx.limits.lock().unwrap().disconnect(&ip);
    let _ = ev.send(Event::Closed { id, by_client }).await;
}

async fn writer(mut wr: OwnedWriteHalf, shared: Arc<Shared>, mut rx: mpsc::Receiver<Out>, mut kill: watch::Receiver<bool>, write_timeout: Duration) {
    let mut enc: Option<Cfb8> = None;
    loop {
        let msg = tokio::select! {
            _ = kill.changed() => break,
            m = rx.recv() => match m { Some(m) => m, None => break },
        };
        match msg {
            Out::Data(mut d) => {
                if enc.is_none() {
                    if let Some(k) = shared.enc_key.lock().unwrap().take() {
                        enc = Some(Cfb8::new(&k)); // everything queued from here on is encrypted
                    }
                }
                if let Some(e) = enc.as_mut() {
                    e.encrypt(&mut d);
                }
                let n = d.len();
                let r = tokio::time::timeout(write_timeout, wr.write_all(&d)).await;
                shared.pending.fetch_sub(n, Ordering::Relaxed);
                if !matches!(r, Ok(Ok(()))) {
                    break;
                }
            }
            Out::Close => {
                let _ = wr.shutdown().await;
                break;
            }
        }
    }
    let _ = shared.kill.send(true);
}
