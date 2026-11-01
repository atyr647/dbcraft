//! Configuration: a TOML file (optional) with environment overrides `DBCRAFT_GW_<NAME>`, e.g. DBCRAFT_GW_DATABASE_URL, DBCRAFT_GW_LISTEN.
//! The tick rate and the tick/drain functions can also be set in the database (net.setting keys tick_ms, gateway_tick, gateway_drain): the database wins.

use serde::Deserialize;

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct Config {
    pub database_url: String,
    pub listen: String,
    pub tick_ms: u64,
    pub tick_fn: String,
    pub drain_fn: String,
    pub max_connections: usize,
    pub max_connections_per_ip: usize,
    pub new_connections_per_ip_per_sec: u32,
    pub login_attempts_per_ip_per_min: u32,
    pub read_timeout_s: u64,
    pub write_timeout_s: u64,
    pub max_pending_bytes: usize,
    pub prelogin_max_frame: usize,
    pub prelogin_max_bytes: usize,
    pub session_url: String,
    pub session_timeout_ms: u64,
    pub session_concurrency: usize,
    pub session_retries: u32,
    pub rsa_bits: usize,
    pub stats: bool,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            database_url: "host=/tmp port=5432 user=postgres dbname=dbcraft".into(),
            listen: "0.0.0.0:25565".into(),
            tick_ms: 50,
            tick_fn: "mc.server_tick()".into(),
            drain_fn: "net.drain_outbox()".into(),
            max_connections: 20_000,
            max_connections_per_ip: 16,
            new_connections_per_ip_per_sec: 5,
            login_attempts_per_ip_per_min: 20,
            read_timeout_s: 30,
            write_timeout_s: 30,
            max_pending_bytes: 8 * 1024 * 1024,
            prelogin_max_frame: 32_768,
            prelogin_max_bytes: 262_144,
            session_url: "https://sessionserver.mojang.com".into(),
            session_timeout_ms: 5_000,
            session_concurrency: 64,
            session_retries: 1,
            rsa_bits: 1024,
            stats: true,
        }
    }
}

/// Only identifiers, dots and a trailing "()" may appear in a function name that is spliced into SQL.
pub fn valid_sql_call(s: &str) -> bool {
    !s.is_empty() && s.ends_with("()") && s[..s.len() - 2].chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '.')
}

impl Config {
    pub fn load(path: Option<&str>) -> Result<Config, String> {
        let mut c: Config = match path {
            Some(p) => toml::from_str(&std::fs::read_to_string(p).map_err(|e| format!("{p}: {e}"))?).map_err(|e| format!("{p}: {e}"))?,
            None => Config::default(),
        };
        let env = |k: &str| std::env::var(format!("DBCRAFT_GW_{k}")).ok();
        macro_rules! ov {
            ($field:ident, $name:expr) => {
                if let Some(v) = env($name) {
                    c.$field = v.parse().map_err(|_| format!("DBCRAFT_GW_{}: cannot parse {:?}", $name, v))?;
                }
            };
        }
        ov!(database_url, "DATABASE_URL");
        ov!(listen, "LISTEN");
        ov!(tick_ms, "TICK_MS");
        ov!(tick_fn, "TICK_FN");
        ov!(drain_fn, "DRAIN_FN");
        ov!(max_connections, "MAX_CONNECTIONS");
        ov!(max_connections_per_ip, "MAX_CONNECTIONS_PER_IP");
        ov!(new_connections_per_ip_per_sec, "NEW_CONNECTIONS_PER_IP_PER_SEC");
        ov!(login_attempts_per_ip_per_min, "LOGIN_ATTEMPTS_PER_IP_PER_MIN");
        ov!(read_timeout_s, "READ_TIMEOUT_S");
        ov!(write_timeout_s, "WRITE_TIMEOUT_S");
        ov!(max_pending_bytes, "MAX_PENDING_BYTES");
        ov!(prelogin_max_frame, "PRELOGIN_MAX_FRAME");
        ov!(prelogin_max_bytes, "PRELOGIN_MAX_BYTES");
        ov!(session_url, "SESSION_URL");
        ov!(session_timeout_ms, "SESSION_TIMEOUT_MS");
        ov!(session_concurrency, "SESSION_CONCURRENCY");
        ov!(session_retries, "SESSION_RETRIES");
        ov!(rsa_bits, "RSA_BITS");
        ov!(stats, "STATS");
        if !valid_sql_call(&c.tick_fn) || !valid_sql_call(&c.drain_fn) {
            return Err("tick_fn and drain_fn must look like schema.function()".into());
        }
        if c.tick_ms == 0 || c.tick_ms > 1000 {
            return Err("tick_ms must be between 1 and 1000".into());
        }
        Ok(c)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn sql_calls_are_validated() {
        assert!(valid_sql_call("mc.server_tick()"));
        assert!(valid_sql_call("net.drain_outbox()"));
        assert!(!valid_sql_call("mc.server_tick(); drop table x"));
        assert!(!valid_sql_call("mc.server_tick"));
        assert!(!valid_sql_call(""));
        assert!(!valid_sql_call("a b()"));
    }
    #[test]
    fn defaults_load() {
        let c = Config::load(None).unwrap();
        assert_eq!(c.tick_ms, 50);
    }
}
