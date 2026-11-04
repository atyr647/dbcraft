//! Chunk generator threads: connections of their own that run `call mc.run_generator_until_idle(...)` (sql/970) when the database has chunk requests, and sleep otherwise.
//!
//! Why here and not as `call mc.run_generator()` loops started by hand: a generator that polls for work wakes up 20 times a second for ever, and two of them were a third
//! of an idle server's CPU (docs/PERF-IDLE2.md).  The tick connection already probes the database every tick (`net.gateway_pending`, bit 4: a row in mc.chunk_request), so the
//! gateway knows within one tick when there is something to generate and wakes the threads; a woken thread polls every 5 ms like the old loop, generates, and parks again after
//! `exit_idle_ms` without work.  A chunk request therefore waits for a generator exactly as long as before (one tick for the probe, at most 5 ms for the poll) and an idle server
//! has no polling at all.  The old loops keep working (`call mc.run_generator()`), these threads are only started when `generators` > 0 in the settings.

use crate::ffi::pq::Pg;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::Duration;

struct Shared {
    stop: AtomicBool,
    wake: Mutex<bool>,
    cv: Condvar,
    /// workers currently inside a generator call
    active: AtomicUsize,
    runs: AtomicU64,
    errors: AtomicU64,
}

pub struct Generators {
    n: usize,
    shared: Arc<Shared>,
    handles: Vec<thread::JoinHandle<()>>,
}

impl Generators {
    pub fn spawn(database_url: &str, n: usize, batch: u32, exit_idle_ms: u32) -> Generators {
        let shared = Arc::new(Shared { stop: AtomicBool::new(false), wake: Mutex::new(true), cv: Condvar::new(), active: AtomicUsize::new(0), runs: AtomicU64::new(0), errors: AtomicU64::new(0) });
        let mut handles = Vec::new();
        for i in 0..n {
            let (s, url) = (Arc::clone(&shared), database_url.to_string());
            if let Ok(h) = thread::Builder::new().name(format!("generator-{i}")).spawn(move || run(url, batch, exit_idle_ms, s)) {
                handles.push(h);
            }
        }
        Generators { n, shared, handles }
    }

    /// Chunk requests exist: wake the threads that are parked (a no-op for the ones that are generating).
    pub fn wake(&self) {
        if self.shared.active.load(Ordering::Relaxed) >= self.n {
            return;
        }
        let mut w = self.shared.wake.lock().unwrap_or_else(|e| e.into_inner());
        *w = true;
        drop(w);
        self.shared.cv.notify_all();
    }

    /// Stops the threads: parked ones return at once, one inside a generator call finishes it (it ends by itself after `exit_idle_ms` without work; the process ends anyway).
    /// Returns (generator calls, errors).
    pub fn stop(mut self) -> (u64, u64) {
        self.shared.stop.store(true, Ordering::Relaxed);
        self.shared.cv.notify_all();
        if self.shared.active.load(Ordering::Relaxed) == 0 {
            for h in self.handles.drain(..) {
                let _ = h.join();
            }
        }
        (self.shared.runs.load(Ordering::Relaxed), self.shared.errors.load(Ordering::Relaxed))
    }
}

fn run(url: String, batch: u32, exit_idle_ms: u32, s: Arc<Shared>) {
    let mut db: Option<Pg> = None;
    let call = format!("call mc.run_generator_until_idle({batch}, 5, {exit_idle_ms})");
    loop {
        {
            let mut w = s.wake.lock().unwrap_or_else(|e| e.into_inner());
            while !*w && !s.stop.load(Ordering::Relaxed) {
                w = s.cv.wait_timeout(w, Duration::from_secs(30)).unwrap_or_else(|e| e.into_inner()).0;
            }
            if s.stop.load(Ordering::Relaxed) {
                return;
            }
            *w = false;
        }
        if db.as_ref().map(|d| !d.is_ok()).unwrap_or(true) {
            match Pg::connect(&url) {
                Ok(c) => db = Some(c),
                Err(e) => {
                    if s.errors.fetch_add(1, Ordering::Relaxed) % 60 == 0 {
                        eprintln!("[gw generator] cannot connect: {e}");
                    }
                    thread::sleep(Duration::from_secs(1));
                    *s.wake.lock().unwrap_or_else(|e| e.into_inner()) = true; // try again
                    continue;
                }
            }
        }
        let d = db.as_mut().expect("connected above");
        s.active.fetch_add(1, Ordering::Relaxed);
        // generate until the call finds nothing to do for exit_idle_ms; then look once more (a request may have arrived while it returned) before parking
        loop {
            match d.exec(&call) {
                Ok(_) => {
                    s.runs.fetch_add(1, Ordering::Relaxed);
                }
                Err(e) => {
                    if s.errors.fetch_add(1, Ordering::Relaxed) % 60 == 0 {
                        eprintln!("[gw generator] call failed: {e}");
                    }
                    thread::sleep(Duration::from_millis(500));
                    break;
                }
            }
            if s.stop.load(Ordering::Relaxed) {
                break;
            }
            match d.exec("select exists (select 1 from mc.chunk_request)") {
                Ok(r) if r.boolean(0, 0).unwrap_or(false) => continue,
                _ => break,
            }
        }
        s.active.fetch_sub(1, Ordering::Relaxed);
    }
}
