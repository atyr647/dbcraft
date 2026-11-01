//! The session-server check (Mojang's hasJoined), with a pooled async client and a bounded number of requests in flight.
//! Verdicts, as vanilla's authlib maps them: a profile = ok; 204 or another 4xx = an invalid session (multiplayer.disconnect.unverified_username);
//! 429, 5xx, a timeout or a network error = unavailable (multiplayer.disconnect.authservers_down).  Retries only for "unavailable", only once by default,
//! and never after an answer: a successful hasJoined is single-use on the real service.

use serde::Deserialize;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::Semaphore;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AuthError {
    Invalid,
    Unavailable,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Property {
    pub name: String,
    pub value: String,
    #[serde(default)]
    pub signature: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct RawProfile {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub properties: Vec<Property>,
}

#[derive(Debug, Clone)]
pub struct Profile {
    /// canonical 8-4-4-4-12 form
    pub uuid: String,
    pub name: String,
    pub properties: Vec<Property>,
}

pub fn dashed_uuid(h: &str) -> Option<String> {
    if h.len() != 32 || !h.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    Some(format!("{}-{}-{}-{}-{}", &h[0..8], &h[8..12], &h[12..16], &h[16..20], &h[20..32]).to_ascii_lowercase())
}

pub fn parse_profile(body: &[u8]) -> Result<Profile, AuthError> {
    let raw: RawProfile = serde_json::from_slice(body).map_err(|_| AuthError::Unavailable)?;
    let uuid = dashed_uuid(&raw.id).ok_or(AuthError::Invalid)?;
    Ok(Profile { uuid, name: raw.name, properties: raw.properties })
}

#[derive(Clone)]
pub struct SessionClient {
    client: reqwest::Client,
    base: String,
    limiter: Arc<Semaphore>,
    retries: u32,
    timeout: Duration,
}

impl SessionClient {
    pub fn new(base: &str, timeout_ms: u64, concurrency: usize, retries: u32) -> Result<SessionClient, String> {
        let client = reqwest::Client::builder()
            .pool_max_idle_per_host(concurrency.max(1))
            .connect_timeout(Duration::from_millis(timeout_ms))
            .build()
            .map_err(|e| format!("http client: {e}"))?;
        Ok(SessionClient { client, base: base.trim_end_matches('/').to_string(), limiter: Arc::new(Semaphore::new(concurrency.max(1))), retries, timeout: Duration::from_millis(timeout_ms) })
    }

    pub async fn has_joined(&self, username: &str, server_hash: &str) -> Result<Profile, AuthError> {
        let _permit = self.limiter.acquire().await.map_err(|_| AuthError::Unavailable)?;
        let url = format!("{}/session/minecraft/hasJoined", self.base);
        let mut last = AuthError::Unavailable;
        for attempt in 0..=self.retries {
            if attempt > 0 {
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
            let r = self.client.get(&url).query(&[("username", username), ("serverId", server_hash)]).timeout(self.timeout).send().await;
            match r {
                Ok(resp) => {
                    let st = resp.status();
                    if st.as_u16() == 200 {
                        let body = resp.bytes().await.map_err(|_| AuthError::Unavailable);
                        match body {
                            Ok(b) if !b.is_empty() => return parse_profile(&b),
                            Ok(_) => return Err(AuthError::Invalid),
                            Err(e) => last = e,
                        }
                    } else if st.as_u16() == 429 || st.is_server_error() {
                        last = AuthError::Unavailable;
                    } else {
                        return Err(AuthError::Invalid); // 204, 403, 404 ...: the session is not valid
                    }
                }
                Err(_) => last = AuthError::Unavailable,
            }
        }
        Err(last)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uuid_formatting() {
        assert_eq!(dashed_uuid("069a79f444e94726a5befca90e38aaf5").unwrap(), "069a79f4-44e9-4726-a5be-fca90e38aaf5");
        assert!(dashed_uuid("short").is_none());
        assert!(dashed_uuid("zz9a79f444e94726a5befca90e38aaf5").is_none());
    }

    #[test]
    fn profile_parsing() {
        let body = br#"{"id":"069a79f444e94726a5befca90e38aaf5","name":"Notch","properties":[{"name":"textures","value":"VAL","signature":"SIG"},{"name":"x","value":"y"}]}"#;
        let p = parse_profile(body).unwrap();
        assert_eq!(p.uuid, "069a79f4-44e9-4726-a5be-fca90e38aaf5");
        assert_eq!(p.name, "Notch");
        assert_eq!(p.properties.len(), 2);
        assert_eq!(p.properties[0].signature.as_deref(), Some("SIG"));
        assert_eq!(p.properties[1].signature, None);
        assert_eq!(parse_profile(b"not json").unwrap_err(), AuthError::Unavailable);
        assert_eq!(parse_profile(br#"{"id":"bad","name":"n"}"#).unwrap_err(), AuthError::Invalid);
    }
}
