//! Per-address limits: concurrent connections, new connections per second, login attempts (encryption responses; each costs an RSA decryption) per minute, and a total cap.
//! Time is passed in so the tests need no sleeping.  A limit of 0 means "unlimited".

use std::collections::{HashMap, VecDeque};
use std::net::IpAddr;
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy)]
pub struct LimitConfig {
    pub max_connections: usize,
    pub max_per_ip: usize,
    pub new_per_ip_per_sec: u32,
    pub logins_per_ip_per_min: u32,
}

pub struct Limits {
    cfg: LimitConfig,
    per_ip: HashMap<IpAddr, usize>,
    recent: HashMap<IpAddr, VecDeque<Instant>>,
    logins: HashMap<IpAddr, VecDeque<Instant>>,
    total: usize,
}

fn prune(q: &mut VecDeque<Instant>, now: Instant, window: Duration) {
    while q.front().map_or(false, |t| now.saturating_duration_since(*t) > window) {
        q.pop_front();
    }
}

impl Limits {
    pub fn new(cfg: LimitConfig) -> Limits {
        Limits { cfg, per_ip: HashMap::new(), recent: HashMap::new(), logins: HashMap::new(), total: 0 }
    }

    #[cfg(test)]
    pub fn total(&self) -> usize {
        self.total
    }

    /// Registers a new connection; false = refuse it (the caller drops the socket).
    pub fn connect(&mut self, ip: IpAddr, now: Instant) -> bool {
        if self.cfg.max_connections > 0 && self.total >= self.cfg.max_connections {
            return false;
        }
        if self.cfg.max_per_ip > 0 && self.per_ip.get(&ip).copied().unwrap_or(0) >= self.cfg.max_per_ip {
            return false;
        }
        if self.cfg.new_per_ip_per_sec > 0 {
            let q = self.recent.entry(ip).or_default();
            prune(q, now, Duration::from_secs(1));
            if q.len() as u32 >= self.cfg.new_per_ip_per_sec {
                return false;
            }
            q.push_back(now);
        }
        *self.per_ip.entry(ip).or_insert(0) += 1;
        self.total += 1;
        true
    }

    pub fn disconnect(&mut self, ip: IpAddr) {
        if let Some(n) = self.per_ip.get_mut(&ip) {
            *n -= 1;
            if *n == 0 {
                self.per_ip.remove(&ip);
            }
        }
        self.total = self.total.saturating_sub(1);
    }

    /// An encryption response arrived from this address: may we spend an RSA decryption on it?
    pub fn login_allowed(&mut self, ip: IpAddr, now: Instant) -> bool {
        if self.cfg.logins_per_ip_per_min == 0 {
            return true;
        }
        let q = self.logins.entry(ip).or_default();
        prune(q, now, Duration::from_secs(60));
        if q.len() as u32 >= self.cfg.logins_per_ip_per_min {
            return false;
        }
        q.push_back(now);
        true
    }

    /// Forgets idle addresses (call about once a minute) so the maps cannot grow without bound.
    pub fn sweep(&mut self, now: Instant) {
        self.recent.retain(|_, q| q.back().map_or(false, |t| now.saturating_duration_since(*t) < Duration::from_secs(2)));
        self.logins.retain(|_, q| q.back().map_or(false, |t| now.saturating_duration_since(*t) < Duration::from_secs(61)));
    }

    #[cfg(test)]
    pub fn tracked_addresses(&self) -> usize {
        self.per_ip.len() + self.recent.len() + self.logins.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ip(n: u8) -> IpAddr {
        IpAddr::from([10, 0, 0, n])
    }
    fn cfg() -> LimitConfig {
        LimitConfig { max_connections: 5, max_per_ip: 2, new_per_ip_per_sec: 3, logins_per_ip_per_min: 2 }
    }

    #[test]
    fn per_address_and_total_caps() {
        let mut l = Limits::new(cfg());
        let t = Instant::now();
        assert!(l.connect(ip(1), t));
        assert!(l.connect(ip(1), t));
        assert!(!l.connect(ip(1), t), "third from one address");
        assert!(l.connect(ip(2), t) && l.connect(ip(3), t) && l.connect(ip(4), t));
        assert!(!l.connect(ip(5), t), "sixth overall");
        l.disconnect(ip(1));
        assert!(l.connect(ip(5), t));
        assert_eq!(l.total(), 5);
    }

    #[test]
    fn rate_of_new_connections_uses_a_sliding_window() {
        let mut l = Limits::new(LimitConfig { max_connections: 0, max_per_ip: 0, new_per_ip_per_sec: 3, logins_per_ip_per_min: 0 });
        let t = Instant::now();
        for _ in 0..3 {
            assert!(l.connect(ip(1), t));
        }
        assert!(!l.connect(ip(1), t));
        assert!(l.connect(ip(2), t), "another address is unaffected");
        assert!(l.connect(ip(1), t + Duration::from_millis(1100)), "a second later it is allowed again");
    }

    #[test]
    fn login_attempts_per_minute() {
        let mut l = Limits::new(cfg());
        let t = Instant::now();
        assert!(l.login_allowed(ip(1), t));
        assert!(l.login_allowed(ip(1), t));
        assert!(!l.login_allowed(ip(1), t));
        assert!(l.login_allowed(ip(1), t + Duration::from_secs(61)));
    }

    #[test]
    fn zero_means_unlimited() {
        let mut l = Limits::new(LimitConfig { max_connections: 0, max_per_ip: 0, new_per_ip_per_sec: 0, logins_per_ip_per_min: 0 });
        let t = Instant::now();
        for _ in 0..1000 {
            assert!(l.connect(ip(1), t));
            assert!(l.login_allowed(ip(1), t));
        }
    }

    #[test]
    fn sweep_forgets_idle_addresses() {
        let mut l = Limits::new(cfg());
        let t = Instant::now();
        for n in 0..200u8 {
            l.connect(ip(n), t);
            l.disconnect(ip(n));
            l.login_allowed(ip(n), t);
        }
        assert!(l.tracked_addresses() > 100);
        l.sweep(t + Duration::from_secs(120));
        assert_eq!(l.tracked_addresses(), 0);
    }
}
