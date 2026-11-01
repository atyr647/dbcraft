//! dbcraft-gateway [config.toml]   (see gateway/README.md; environment overrides DBCRAFT_GW_*)

#[tokio::main]
async fn main() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();
    let path = std::env::args().nth(1);
    let cfg = match dbcraft_gateway::config::Config::load(path.as_deref()) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("configuration: {e}");
            std::process::exit(2);
        }
    };
    if let Err(e) = dbcraft_gateway::gateway::run(cfg).await {
        eprintln!("gateway stopped: {e}");
        std::process::exit(1);
    }
}
