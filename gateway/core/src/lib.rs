//! The gateway's core, standard library only, so it builds and is tested anywhere (no crates, no build scripts).
//! The async runtime, Postgres client, RSA and HTTPS live in the main crate and use this one for everything protocol-shaped.

pub mod aes;
pub mod frame;
pub mod hash;
pub mod inflate;
pub mod sha1;
