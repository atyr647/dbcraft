//! The session-server check (Mojang's hasJoined) for online mode.  A fixed pool of worker threads, each with its own curl handle (connections are kept alive between
//! requests), takes jobs from a bounded queue and posts verdicts to the event loop, which is woken through an eventfd.  Pooled and bounded because one serialised
//! HTTP client capped at about 20 requests per second in the Elixir evaluation.
//!
//! Verdicts mirror the reference gateway (sql/optional/dev_gateway_online.sql):
//!   200 with a profile                      -> Ok(uuid, name, properties)
//!   200 with an empty body, 204, 4xx        -> Invalid      (multiplayer.disconnect.unverified_username)
//!   429, 5xx, timeouts, network errors,
//!   an answer that is not a profile         -> Unavailable  (multiplayer.disconnect.authservers_down)
//! The session server is asked exactly once per login when it gives an answer (a successful hasJoined is single use on the real service); only "unavailable" is retried.

use crate::ffi::curl::{percent_encode, CurlError, Easy};
use crate::ffi::sys::EventFd;
use crate::json;
use std::collections::VecDeque;
use std::sync::mpsc::{sync_channel, Receiver, SyncSender, TrySendError};
use std::sync::{Arc, Mutex};
use std::time::Duration;

#[derive(Debug, Clone, PartialEq)]
pub enum Outcome {
    Ok { uuid: String, name: String, properties: String },
    Invalid,
    Unavailable,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Verdict {
    pub conn_id: u64,
    pub outcome: Outcome,
}

struct Job {
    conn_id: u64,
    name: String,
    server_hash: String,
}

#[derive(Clone)]
pub struct PoolConfig {
    pub base_url: String,
    pub timeout_ms: u64,
    pub workers: usize,
    pub retries: u32,
}

pub struct SessionPool {
    tx: SyncSender<Job>,
    results: Arc<Mutex<VecDeque<Verdict>>>,
    wake: Arc<EventFd>,
}

const MAX_RESPONSE: usize = 128 * 1024;

/// Turns an HTTP answer into a verdict (pure: tested without a network).
pub fn classify(status: u32, body: &[u8]) -> Outcome {
    match status {
        200 => {
            if body.iter().all(|b| b.is_ascii_whitespace()) {
                return Outcome::Invalid;
            }
            match parse_profile(body) {
                Some((uuid, name, properties)) => Outcome::Ok { uuid, name, properties },
                None => Outcome::Unavailable,
            }
        }
        204 => Outcome::Invalid,
        429 => Outcome::Unavailable,
        s if s >= 500 => Outcome::Unavailable,
        s if (400..500).contains(&s) => Outcome::Invalid,
        _ => Outcome::Unavailable,
    }
}

/// `{"id": "<32 hex>", "name": "...", "properties": [...]}` -> (dashed uuid, name, properties as compact JSON text)
pub fn parse_profile(body: &[u8]) -> Option<(String, String, String)> {
    let v = json::parse(body).ok()?;
    let id = v.get("id")?.as_str()?;
    if id.len() != 32 || !id.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    let name = v.get("name")?.as_str()?;
    if name.is_empty() || name.len() > 64 {
        return None;
    }
    let uuid = format!("{}-{}-{}-{}-{}", &id[0..8], &id[8..12], &id[12..16], &id[16..20], &id[20..32]).to_ascii_lowercase();
    let props = match v.get("properties") {
        None | Some(json::Value::Null) => "[]".to_string(),
        Some(p @ json::Value::Arr(items)) => {
            if items.len() > 64 {
                return None;
            }
            json::to_json(p)
        }
        Some(_) => return None,
    };
    Some((uuid, name.to_string(), props))
}

pub fn build_url(base: &str, name: &str, server_hash: &str) -> String {
    format!("{}/session/minecraft/hasJoined?username={}&serverId={}", base.trim_end_matches('/'), percent_encode(name), percent_encode(server_hash))
}

fn run_job(easy: &mut Easy, cfg: &PoolConfig, job: &Job) -> Outcome {
    let url = build_url(&cfg.base_url, &job.name, &job.server_hash);
    let mut attempt = 0;
    loop {
        let outcome = match easy.get(&url, cfg.timeout_ms, MAX_RESPONSE) {
            Ok((status, body)) => classify(status, &body),
            Err(CurlError::Transfer(_)) | Err(CurlError::TooLarge) | Err(CurlError::Setup(_)) | Err(CurlError::Init) => Outcome::Unavailable,
        };
        if outcome != Outcome::Unavailable || attempt >= cfg.retries {
            return outcome;
        }
        attempt += 1;
        std::thread::sleep(Duration::from_millis(100));
    }
}

impl SessionPool {
    pub fn start(cfg: PoolConfig, wake: Arc<EventFd>) -> Result<SessionPool, String> {
        crate::ffi::curl::global_init();
        let (tx, rx) = sync_channel::<Job>(4096);
        let rx: Arc<Mutex<Receiver<Job>>> = Arc::new(Mutex::new(rx));
        let results = Arc::new(Mutex::new(VecDeque::new()));
        for i in 0..cfg.workers {
            let mut easy = Easy::new().map_err(|e| format!("curl: {e:?}"))?;
            let rx = Arc::clone(&rx);
            let results = Arc::clone(&results);
            let wake = Arc::clone(&wake);
            let cfg = cfg.clone();
            std::thread::Builder::new()
                .name(format!("session-{i}"))
                .spawn(move || loop {
                    // hold the receiver lock only while waiting for a job, not while working
                    let job = match rx.lock().map(|g| g.recv()) {
                        Ok(Ok(j)) => j,
                        _ => return, // channel closed: the gateway is shutting down
                    };
                    let outcome = run_job(&mut easy, &cfg, &job);
                    if let Ok(mut q) = results.lock() {
                        q.push_back(Verdict { conn_id: job.conn_id, outcome });
                    }
                    wake.notify();
                })
                .map_err(|e| format!("cannot start a session worker: {e}"))?;
        }
        Ok(SessionPool { tx, results, wake })
    }

    /// Queues a check.  If the queue is full the verdict is "unavailable" immediately (an overloaded session service must not stall the loop).
    pub fn submit(&self, conn_id: u64, name: String, server_hash: String) {
        match self.tx.try_send(Job { conn_id, name, server_hash }) {
            Ok(()) => {}
            Err(TrySendError::Full(j)) | Err(TrySendError::Disconnected(j)) => {
                if let Ok(mut q) = self.results.lock() {
                    q.push_back(Verdict { conn_id: j.conn_id, outcome: Outcome::Unavailable });
                }
                self.wake.notify();
            }
        }
    }

    /// The verdicts that have arrived since the last call.
    pub fn take(&self) -> Vec<Verdict> {
        match self.results.lock() {
            Ok(mut q) => q.drain(..).collect(),
            Err(_) => Vec::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const GOOD: &[u8] = br#"{"id":"069a79f444e94726a5befca90e38aaf5","name":"Notch","properties":[{"name":"textures","value":"abc=","signature":"sig=="}]}"#;

    #[test]
    fn a_profile_becomes_a_dashed_uuid_name_and_properties() {
        match classify(200, GOOD) {
            Outcome::Ok { uuid, name, properties } => {
                assert_eq!(uuid, "069a79f4-44e9-4726-a5be-fca90e38aaf5");
                assert_eq!(name, "Notch");
                assert_eq!(properties, r#"[{"name":"textures","value":"abc=","signature":"sig=="}]"#);
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn status_codes_map_like_the_reference_gateway() {
        assert_eq!(classify(204, b""), Outcome::Invalid);
        assert_eq!(classify(200, b""), Outcome::Invalid);
        assert_eq!(classify(200, b"  \n"), Outcome::Invalid);
        assert_eq!(classify(403, b"{}"), Outcome::Invalid);
        assert_eq!(classify(404, b""), Outcome::Invalid);
        assert_eq!(classify(429, b""), Outcome::Unavailable);
        assert_eq!(classify(500, b""), Outcome::Unavailable);
        assert_eq!(classify(503, b""), Outcome::Unavailable);
        assert_eq!(classify(302, b""), Outcome::Unavailable);
    }

    #[test]
    fn answers_that_are_not_profiles_are_unavailable() {
        for bad in [
            &b"not json"[..],
            br#"{"id":"zz9a79f444e94726a5befca90e38aaf5","name":"x"}"#,
            br#"{"id":"069a79f444e94726a5befca90e38aaf","name":"x"}"#,
            br#"{"id":"069a79f444e94726a5befca90e38aaf5"}"#,
            br#"{"id":"069a79f444e94726a5befca90e38aaf5","name":""}"#,
            br#"{"id":"069a79f444e94726a5befca90e38aaf5","name":"x","properties":"nope"}"#,
            br#"[1,2,3]"#,
        ] {
            assert_eq!(classify(200, bad), Outcome::Unavailable, "{}", String::from_utf8_lossy(bad));
        }
    }

    #[test]
    fn missing_properties_mean_an_empty_list() {
        match classify(200, br#"{"id":"069a79f444e94726a5befca90e38aaf5","name":"x"}"#) {
            Outcome::Ok { properties, .. } => assert_eq!(properties, "[]"),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn urls_are_encoded() {
        assert_eq!(
            build_url("http://127.0.0.1:9/", "Notch", "-7c9d5b"),
            "http://127.0.0.1:9/session/minecraft/hasJoined?username=Notch&serverId=-7c9d5b"
        );
        assert!(build_url("http://x", "a&b=c", "h").contains("username=a%26b%3Dc"));
    }

    #[test]
    fn an_unreachable_session_server_gives_unavailable_and_wakes_the_loop() {
        let wake = Arc::new(EventFd::new().unwrap());
        let pool = SessionPool::start(PoolConfig { base_url: "http://127.0.0.1:1".into(), timeout_ms: 300, workers: 2, retries: 0 }, Arc::clone(&wake)).unwrap();
        pool.submit(7, "Probe".into(), "abc".into());
        let mut got = Vec::new();
        for _ in 0..100 {
            got = pool.take();
            if !got.is_empty() {
                break;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        assert_eq!(got, vec![Verdict { conn_id: 7, outcome: Outcome::Unavailable }]);
    }
}
