//! Configuration: an optional `key = value` file (lines starting with `#` are comments) and environment overrides `DBCRAFT_GW_<NAME>`.
//! Settings that live in the database (net.setting: tick_ms, session_url, session_timeout_s) are read at start and win over the defaults, not over an explicit
//! file/environment value that differs from the default.

use std::collections::HashMap;

#[derive(Debug, Clone, PartialEq)]
pub struct Config {
    pub database_url: String,
    pub listen: String,
    pub tick_ms: u64,
    /// the server tick: mc.server_tick() or mc.server_tick_batched()
    pub tick_fn: String,
    pub max_connections: usize,
    pub max_connections_per_ip: usize,
    pub new_connections_per_ip_per_sec: u32,
    pub login_attempts_per_ip_per_min: u32,
    pub read_timeout_s: u64,
    pub max_pending_bytes: usize,
    pub prelogin_max_frame: usize,
    pub prelogin_max_bytes: usize,
    pub session_url: String,
    pub session_timeout_ms: u64,
    pub session_workers: usize,
    pub session_retries: u32,
    pub rsa_bits: u32,
    /// how the tick's inbound frames reach the database: "copy" (binary COPY) or "unnest" (one INSERT with array parameters)
    pub inbox_mode: String,
    /// seconds between the maintenance passes (a thread with its own connection: VACUUM (ANALYZE, SKIP_LOCKED) of `maintenance_tables`); 0 = off.  docs/SOAK.md
    pub maintenance_s: u64,
    /// schema-qualified tables, separated by commas or spaces: the tables that grow by DELETE/UPDATE and that autovacuum is too slow for (default: see below)
    pub maintenance_tables: String,
}

/// Tables vacuumed by the maintenance thread: NOT the queues net.inbox/net.outbox (net.drain_outbox() truncates them: a vacuum of a queue that is empty at that moment
/// would only store reltuples = 0, see sql/435 and sql/780).
pub const DEFAULT_MAINTENANCE_TABLES: &str = "net.conn, mc.player, mc.visible, mc.chunk_wanted, mc.chunk_request, mc.play_in, mc.pending_ack, mc.kick, mc.block_event, \
mc.block_actor, mc.game_state, mc.server_tick_log, mc.tick_log, net.gateway_control, net.gateway_stats";

/// A table list is spliced into a VACUUM statement: only identifiers of the form schema.table (lower-case letters, digits, underscore) are accepted.
pub fn valid_table_list(s: &str) -> bool {
    let items: Vec<&str> = s.split(|c: char| c == ',' || c.is_whitespace()).filter(|t| !t.is_empty()).collect();
    !items.is_empty()
        && items.iter().all(|t| {
            let mut parts = t.split('.');
            let (a, b, c) = (parts.next(), parts.next(), parts.next());
            let ident = |p: &str| !p.is_empty() && p.len() <= 63 && p.chars().all(|ch| ch.is_ascii_lowercase() || ch.is_ascii_digit() || ch == '_') && !p.starts_with(|ch: char| ch.is_ascii_digit());
            c.is_none() && matches!((a, b), (Some(x), Some(y)) if ident(x) && ident(y))
        })
}

impl Default for Config {
    fn default() -> Self {
        Config {
            database_url: "host=/tmp port=5432 user=postgres dbname=dbcraft".into(),
            listen: "0.0.0.0:25565".into(),
            tick_ms: 50,
            tick_fn: "mc.server_tick()".into(),
            max_connections: 20_000,
            max_connections_per_ip: 16,
            new_connections_per_ip_per_sec: 5,
            login_attempts_per_ip_per_min: 20,
            read_timeout_s: 30,
            max_pending_bytes: 8 * 1024 * 1024,
            prelogin_max_frame: 32_768,
            prelogin_max_bytes: 262_144,
            session_url: "https://sessionserver.mojang.com".into(),
            session_timeout_ms: 5_000,
            session_workers: 32,
            session_retries: 1,
            rsa_bits: 1024,
            inbox_mode: "copy".into(),
            maintenance_s: 5,
            maintenance_tables: DEFAULT_MAINTENANCE_TABLES.into(),
        }
    }
}

/// Only these two functions may be spliced into the tick's SQL.
pub fn valid_tick_fn(s: &str) -> bool {
    s == "mc.server_tick()" || s == "mc.server_tick_batched()"
}

/// Parses `key = value` lines.  Unknown keys and malformed lines are errors (a typo must not silently run with a default).
pub fn parse_kv(text: &str) -> Result<HashMap<String, String>, String> {
    let mut m = HashMap::new();
    for (i, raw) in text.lines().enumerate() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let (k, v) = line.split_once('=').ok_or_else(|| format!("line {}: expected key = value", i + 1))?;
        let v = v.trim();
        let v = v.strip_prefix('"').and_then(|x| x.strip_suffix('"')).unwrap_or(v);
        m.insert(k.trim().to_ascii_lowercase(), v.to_string());
    }
    Ok(m)
}

impl Config {
    pub fn apply(&mut self, kv: &HashMap<String, String>) -> Result<(), String> {
        macro_rules! num {
            ($field:ident, $key:expr, $v:expr) => {
                self.$field = $v.parse().map_err(|_| format!("{}: cannot parse {:?}", $key, $v))?
            };
        }
        for (k, v) in kv {
            match k.as_str() {
                "database_url" => self.database_url = v.clone(),
                "listen" => self.listen = v.clone(),
                "tick_ms" => num!(tick_ms, k, v),
                "tick_fn" => self.tick_fn = v.clone(),
                "max_connections" => num!(max_connections, k, v),
                "max_connections_per_ip" => num!(max_connections_per_ip, k, v),
                "new_connections_per_ip_per_sec" => num!(new_connections_per_ip_per_sec, k, v),
                "login_attempts_per_ip_per_min" => num!(login_attempts_per_ip_per_min, k, v),
                "read_timeout_s" => num!(read_timeout_s, k, v),
                "max_pending_bytes" => num!(max_pending_bytes, k, v),
                "prelogin_max_frame" => num!(prelogin_max_frame, k, v),
                "prelogin_max_bytes" => num!(prelogin_max_bytes, k, v),
                "session_url" => self.session_url = v.clone(),
                "session_timeout_ms" => num!(session_timeout_ms, k, v),
                "session_workers" => num!(session_workers, k, v),
                "session_retries" => num!(session_retries, k, v),
                "rsa_bits" => num!(rsa_bits, k, v),
                "inbox_mode" => self.inbox_mode = v.clone(),
                "maintenance_s" => num!(maintenance_s, k, v),
                "maintenance_tables" => self.maintenance_tables = v.clone(),
                other => return Err(format!("unknown setting {other:?}")),
            }
        }
        self.validate()
    }

    pub fn validate(&self) -> Result<(), String> {
        if !valid_tick_fn(&self.tick_fn) {
            return Err("tick_fn must be mc.server_tick() or mc.server_tick_batched()".into());
        }
        if self.tick_ms == 0 || self.tick_ms > 1000 {
            return Err("tick_ms must be between 1 and 1000".into());
        }
        if self.inbox_mode != "copy" && self.inbox_mode != "unnest" {
            return Err("inbox_mode must be copy or unnest".into());
        }
        if self.rsa_bits < 512 || self.rsa_bits > 4096 {
            return Err("rsa_bits must be between 512 and 4096".into());
        }
        if self.session_workers == 0 || self.session_workers > 1024 {
            return Err("session_workers must be between 1 and 1024".into());
        }
        if self.prelogin_max_frame == 0 || self.prelogin_max_frame > 2_097_151 {
            return Err("prelogin_max_frame must be between 1 and 2097151".into());
        }
        if self.maintenance_s > 3600 {
            return Err("maintenance_s must be at most 3600 (0 turns the maintenance off)".into());
        }
        if self.maintenance_s > 0 && !valid_table_list(&self.maintenance_tables) {
            return Err("maintenance_tables must be schema.table names (a-z, 0-9, _) separated by commas or spaces".into());
        }
        Ok(())
    }

    /// Defaults, then the file (if any), then the environment.
    pub fn load(path: Option<&str>, env: &dyn Fn(&str) -> Option<String>) -> Result<Config, String> {
        let mut c = Config::default();
        if let Some(p) = path {
            let text = std::fs::read_to_string(p).map_err(|e| format!("{p}: {e}"))?;
            c.apply(&parse_kv(&text).map_err(|e| format!("{p}: {e}"))?)?;
        }
        let mut over = HashMap::new();
        for key in [
            "database_url", "listen", "tick_ms", "tick_fn", "max_connections", "max_connections_per_ip", "new_connections_per_ip_per_sec", "login_attempts_per_ip_per_min",
            "read_timeout_s", "max_pending_bytes", "prelogin_max_frame", "prelogin_max_bytes", "session_url", "session_timeout_ms", "session_workers", "session_retries",
            "rsa_bits", "inbox_mode", "maintenance_s", "maintenance_tables",
        ] {
            if let Some(v) = env(&format!("DBCRAFT_GW_{}", key.to_ascii_uppercase())) {
                over.insert(key.to_string(), v);
            }
        }
        c.apply(&over)?;
        Ok(c)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn no_env(_: &str) -> Option<String> {
        None
    }

    #[test]
    fn defaults_are_valid() {
        let c = Config::load(None, &no_env).unwrap();
        assert_eq!(c.tick_ms, 50);
        assert_eq!(c.tick_fn, "mc.server_tick()");
    }

    #[test]
    fn kv_parsing() {
        let m = parse_kv("# comment\n\nlisten = 127.0.0.1:1\ntick_ms=20\ndatabase_url = \"host=/tmp dbname=x\"\n").unwrap();
        assert_eq!(m["listen"], "127.0.0.1:1");
        assert_eq!(m["tick_ms"], "20");
        assert_eq!(m["database_url"], "host=/tmp dbname=x");
        assert!(parse_kv("no equals sign").is_err());
    }

    #[test]
    fn unknown_keys_and_bad_values_are_errors() {
        let mut c = Config::default();
        let mut kv = HashMap::new();
        kv.insert("tick_msx".to_string(), "5".to_string());
        assert!(c.apply(&kv).is_err());
        let mut kv = HashMap::new();
        kv.insert("tick_ms".to_string(), "fast".to_string());
        assert!(Config::default().apply(&kv).is_err());
        let mut kv = HashMap::new();
        kv.insert("tick_ms".to_string(), "0".to_string());
        assert!(Config::default().apply(&kv).is_err());
    }

    #[test]
    fn tick_function_is_an_allowlist() {
        assert!(valid_tick_fn("mc.server_tick()"));
        assert!(valid_tick_fn("mc.server_tick_batched()"));
        assert!(!valid_tick_fn("mc.server_tick(); drop table net.conn"));
        assert!(!valid_tick_fn("mc.tick()"));
    }

    #[test]
    fn environment_overrides_the_file_values() {
        let env = |k: &str| if k == "DBCRAFT_GW_LISTEN" { Some("127.0.0.1:9".to_string()) } else { None };
        let c = Config::load(None, &env).unwrap();
        assert_eq!(c.listen, "127.0.0.1:9");
    }
}
