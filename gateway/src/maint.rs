//! Maintenance thread: a connection of its own that vacuums the tables autovacuum is too slow for, every few seconds.  docs/SOAK.md.
//!
//! Why a thread with its own connection: VACUUM cannot run inside a transaction block (the tick's connection is in one), and a vacuum that takes a second must not
//! delay a 50 ms tick.  Why at all: autovacuum looks at a table once per `autovacuum_naptime` (one minute by default) and only after 20 % of it is dead; under 200 walking
//! players the DELETE/UPDATE-heavy tables (mc.chunk_wanted, mc.visible, ...) grow for minutes before it acts.  The development gateway, a single long CALL, needs the same
//! work from tools/janitor.sh because a backend that never goes idle never reports its statistics (tests/soak/stats_flush_probe.sql shows it).
//!
//! The queues net.inbox and net.outbox are deliberately not vacuumed here: net.drain_outbox() truncates them (sql/780).  The statement uses SKIP_LOCKED (never waits
//! behind a tick that holds a table) and ANALYZE (fresh statistics: a stale plan once cost a 4 s tick).  Errors are counted and logged, never fatal.

use crate::ffi::pq::Pg;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::Duration;

/// "a.b, c.d  e.f" -> ["a.b", "c.d", "e.f"].  The caller has validated the list (config::valid_table_list); this only splits.
pub fn split_tables(list: &str) -> Vec<String> {
    list.split(|c: char| c == ',' || c.is_whitespace()).filter(|t| !t.is_empty()).map(|t| t.to_string()).collect()
}

/// The statement that builds the VACUUM statement: only tables that exist are named, so a missing optional table never fails the pass.  `tables` are validated
/// identifiers (lower-case letters, digits, underscore, one dot), so splicing them into a string literal is safe.
pub fn build_statement_sql(tables: &[String]) -> String {
    let list = tables.join(",");
    format!("select format('vacuum (analyze, skip_locked) %s', string_agg(t, ', ')) from unnest(string_to_array('{list}', ',')) t where to_regclass(t) is not null")
}

/// the stop request: the thread sleeps on the condition variable until the next pass is due (no wake-ups in between: a 200 ms sleep loop was five wake-ups a second)
struct StopFlag {
    stopped: Mutex<bool>,
    cv: Condvar,
}

impl StopFlag {
    fn is_set(&self) -> bool {
        *self.stopped.lock().unwrap_or_else(|e| e.into_inner())
    }
    fn set(&self) {
        *self.stopped.lock().unwrap_or_else(|e| e.into_inner()) = true;
        self.cv.notify_all();
    }
    /// Sleeps up to `d`; returns true when a stop was requested.
    fn sleep(&self, d: Duration) -> bool {
        let g = self.stopped.lock().unwrap_or_else(|e| e.into_inner());
        let (g, _) = self.cv.wait_timeout_while(g, d, |s| !*s).unwrap_or_else(|e| e.into_inner());
        *g
    }
}

pub struct Maintenance {
    stop: Arc<StopFlag>,
    passes: Arc<AtomicU64>,
    errors: Arc<AtomicU64>,
    handle: Option<thread::JoinHandle<()>>,
}

impl Maintenance {
    pub fn spawn(database_url: &str, every_s: u64, tables: &str) -> Maintenance {
        let stop = Arc::new(StopFlag { stopped: Mutex::new(false), cv: Condvar::new() });
        let passes = Arc::new(AtomicU64::new(0));
        let errors = Arc::new(AtomicU64::new(0));
        let (url, list) = (database_url.to_string(), split_tables(tables));
        let (s, p, e) = (Arc::clone(&stop), Arc::clone(&passes), Arc::clone(&errors));
        let handle = thread::Builder::new().name("maintenance".into()).spawn(move || run(url, every_s, list, s, p, e)).ok();
        Maintenance { stop, passes, errors, handle }
    }

    /// Stops the thread (it notices at once, or when the vacuum in progress ends) and returns (passes, errors).
    pub fn stop(mut self) -> (u64, u64) {
        self.stop.set();
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
        (self.passes.load(Ordering::Relaxed), self.errors.load(Ordering::Relaxed))
    }
}

fn pass(db: &mut Pg, sql: &str) -> Result<bool, String> {
    let r = db.exec(sql).map_err(|e| e.to_string())?;
    match r.text(0, 0) {
        Some(stmt) if !stmt.is_empty() => {
            db.exec(&stmt).map_err(|e| e.to_string())?;
            Ok(true)
        }
        _ => Ok(false),
    }
}

fn run(url: String, every_s: u64, tables: Vec<String>, stop: Arc<StopFlag>, passes: Arc<AtomicU64>, errors: Arc<AtomicU64>) {
    let sql = build_statement_sql(&tables);
    let mut db: Option<Pg> = None;
    while !stop.is_set() {
        if stop.sleep(Duration::from_secs(every_s)) {
            break;
        }
        if db.as_ref().map(|d| !d.is_ok()).unwrap_or(true) {
            match Pg::connect(&url) {
                Ok(c) => db = Some(c),
                Err(e) => {
                    if errors.fetch_add(1, Ordering::Relaxed) % 60 == 0 {
                        eprintln!("[gw maintenance] cannot connect: {e}");
                    }
                    continue;
                }
            }
        }
        if let Some(d) = db.as_mut() {
            match pass(d, &sql) {
                Ok(_) => {
                    passes.fetch_add(1, Ordering::Relaxed);
                }
                Err(e) => {
                    if errors.fetch_add(1, Ordering::Relaxed) % 60 == 0 {
                        eprintln!("[gw maintenance] pass failed: {e}");
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_on_commas_and_spaces() {
        assert_eq!(split_tables("a.b, c.d  e.f,,g.h"), vec!["a.b", "c.d", "e.f", "g.h"]);
        assert!(split_tables("  , ").is_empty());
    }

    #[test]
    fn statement_names_every_table_once_and_is_one_literal() {
        let sql = build_statement_sql(&["net.conn".to_string(), "mc.player".to_string()]);
        assert!(sql.contains("string_to_array('net.conn,mc.player', ',')"));
        assert!(sql.contains("to_regclass(t) is not null"));
        assert!(sql.contains("skip_locked"));
        assert_eq!(sql.matches('\'').count() % 2, 0, "balanced quotes");
    }

    #[test]
    fn config_accepts_only_schema_dot_table_identifiers() {
        use crate::config::valid_table_list;
        assert!(valid_table_list("net.conn, mc.player"));
        assert!(valid_table_list(crate::config::DEFAULT_MAINTENANCE_TABLES));
        for bad in ["", " , ", "conn", "a.b.c", "a.b; drop table x", "a.b'--", "A.b", "a.1b", "a.b, c d.e", "a..b", ".b", "a.", "mc.player)--"] {
            assert!(!valid_table_list(bad), "{bad:?} must be rejected");
        }
    }
}
