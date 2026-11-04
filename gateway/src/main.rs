//! dbcraft-gateway: the byte pipe between Minecraft clients and the database.  Zero crates.io dependencies: the standard library plus the C libraries
//! already on the machine (libc, libpq, libcrypto, libcurl) through hand-written bindings (src/ffi/).  Build with gateway/build.sh (plain rustc) or `cargo build`.
//!
//! usage: dbcraft-gateway [config-file]        settings: see gateway/README.md; every one has an environment override DBCRAFT_GW_<NAME>

mod config;
mod ffi;
mod gateway;
mod generators;
mod json;
mod keypkt;
mod limits;
mod maint;
mod mojang;
mod reader;
mod wq;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.iter().any(|a| a == "--help" || a == "-h") {
        println!("usage: dbcraft-gateway [config-file]\nsettings are key = value lines; every setting has an environment override DBCRAFT_GW_<NAME> (see gateway/README.md)");
        return;
    }
    if args.iter().any(|a| a == "--version") {
        println!("dbcraft-gateway 0.1.0");
        return;
    }
    let path = args.first().map(|s| s.as_str());
    let cfg = match config::Config::load(path, &|k| std::env::var(k).ok()) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("configuration error: {e}");
            std::process::exit(2);
        }
    };
    // block SIGINT/SIGTERM before any thread exists (threads inherit the mask), and get them as a file descriptor
    let sigfd = match ffi::sys::block_and_open_signals() {
        Ok(fd) => fd,
        Err(e) => {
            eprintln!("cannot set up signal handling: {e}");
            std::process::exit(1);
        }
    };
    ffi::curl::global_init();
    let mut gw = match gateway::Gateway::start(cfg, sigfd) {
        Ok(g) => g,
        Err(e) => {
            eprintln!("cannot start: {e}");
            std::process::exit(1);
        }
    };
    if let Err(e) = gw.run() {
        eprintln!("gateway failed: {e}");
        std::process::exit(1);
    }
}
