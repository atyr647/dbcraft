//! dbcraft gateway: the byte pipe between Minecraft clients and the database.
//!
//! It owns what SQL cannot do (sockets, AES-CFB8, RSA, the Mojang session check, inflating inbound frames) and nothing else: no packet is parsed
//! beyond the one login frame it intercepts, no game state is kept, no rule is applied.  Frames, inflate, AES-CFB8 and the server hash come from the
//! verified std-only `dbcraft-gateway-core`.  See docs/GATEWAY.md.
//!
//! STATUS: the modules below this line were written without a compiler (`cargo build` was not permitted where they were written); the core is tested.

pub mod config;
pub mod conn;
pub mod gateway;
pub mod mojang;
pub mod serverkey;
