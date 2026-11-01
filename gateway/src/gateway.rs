//! The tick loop: every tick (drift-free schedule, 20 Hz by default) ALL events of the tick go to the database in ONE transaction, in this order:
//!   accepted sockets -> net.on_connect;  inbound frames -> ONE binary COPY into net.inbox;  key responses -> net.auth_begun;  session verdicts -> net.auth_result;
//!   net.apply_auth_results();  the server tick (mc.server_tick());  closed sockets -> net.on_disconnect;  net.drain_outbox();  net.gateway_ctl().
//! After the commit the drained bytes are queued to the sockets and the control rows applied.  The gateway keeps no game state: everything it knows
//! about a connection (id, address, compression, play flag, a pending key request) is either in the database too or only meaningful for the socket's life.
//!
//! STATUS: written against the verified core and the contract proven by sql/optional/dev_gateway_online.sql; never compiled here (docs/GATEWAY.md).

use crate::config::{valid_sql_call, Config};
use crate::conn::{spawn_connection, Await, ConnHandle, Ctx, Event, Limits, Out};
use crate::mojang::{AuthError, SessionClient};
use crate::serverkey::ServerKey;
use futures_util::pin_mut;
use std::collections::HashMap;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::net::TcpListener;
use tokio::sync::mpsc;
use tokio_postgres::binary_copy::BinaryCopyInWriter;
use tokio_postgres::types::Type;
use tokio_postgres::NoTls;

type BoxErr = Box<dyn std::error::Error + Send + Sync>;

struct Entry {
    handle: ConnHandle,
}

#[derive(Default)]
struct Stats {
    ticks: i32,
    late: i32,
    tick_ms_sum: f64,
    tick_ms_max: f64,
    db_ms_sum: f64,
    frames_in: i64,
    bytes_in: i64,
    frames_out: i64,
    bytes_out: i64,
    rejected: i32,
    errors: i32,
}

pub async fn run(cfg: Config) -> Result<(), BoxErr> {
    let (mut client, connection) = tokio_postgres::connect(&cfg.database_url, NoTls).await?;
    tokio::spawn(async move {
        if let Err(e) = connection.await {
            log::error!("database connection lost: {e}");
            std::process::exit(2);
        }
    });

    // the key pair: generated now, the public half published for the database to put into encryption requests
    let key = ServerKey::generate(cfg.rsa_bits)?;
    client.execute("insert into net.server_key (id, public_der) values (1, $1) on conflict (id) do update set public_der = excluded.public_der, updated_at = now()", &[&key.public_der]).await?;
    // stale connections of a previous process: their ids would be reused by this one (one gateway process per database for now)
    let stale: i32 = client.query_one("select net.gateway_start()", &[]).await?.get(0);
    if stale > 0 {
        log::warn!("cleaned {stale} stale connection(s) of a previous gateway");
    }
    let key_pkt_id: i32 = client.query_one("select net.pkt('login', 'serverbound', 'minecraft:key')", &[]).await?.get(0);
    let session = SessionClient::new(&cfg.session_url, cfg.session_timeout_ms, cfg.session_concurrency, cfg.session_retries)?;
    let ctx = Arc::new(Ctx { cfg: cfg.clone(), key, key_pkt_id: key_pkt_id as u32, session, limits: Mutex::new(Limits::new()) });

    let (ev_tx, mut ev_rx) = mpsc::channel::<Event>(262_144);
    let listener = TcpListener::bind(&cfg.listen).await?;
    log::info!("listening on {}", cfg.listen);
    {
        let (ctx, ev_tx) = (ctx.clone(), ev_tx.clone());
        tokio::spawn(async move {
            let mut next_id: u64 = 1;
            loop {
                let (stream, addr) = match listener.accept().await {
                    Ok(x) => x,
                    Err(e) => {
                        log::warn!("accept: {e}");
                        tokio::time::sleep(Duration::from_millis(50)).await;
                        continue;
                    }
                };
                let ip = addr.ip().to_string();
                if !ctx.limits.lock().unwrap().connect(&ip, &ctx.cfg) {
                    drop(stream); // over a limit: closed before anything is read
                    continue;
                }
                let id = next_id;
                next_id += 1;
                let handle = spawn_connection(stream, id, ip.clone(), ctx.clone(), ev_tx.clone());
                if ev_tx.send(Event::Connected { id, ip, handle }).await.is_err() {
                    break;
                }
            }
        });
    }

    let mut conns: HashMap<u64, Entry> = HashMap::new();
    let mut last_ctl: i64 = 0;
    let mut tick_ms = cfg.tick_ms;
    let mut tick_fn = cfg.tick_fn.clone();
    let mut drain_fn = cfg.drain_fn.clone();
    let mut stats = Stats::default();
    let mut stats_at = Instant::now();
    let mut sweep_at = Instant::now();
    let mut settings_at = Instant::now() - Duration::from_secs(60);
    let mut next = Instant::now();
    let mut shutdown = Box::pin(tokio::signal::ctrl_c());

    loop {
        // settings kept in the database win over the file, re-read every 5 s
        if settings_at.elapsed() > Duration::from_secs(5) {
            settings_at = Instant::now();
            if let Ok(rows) = client.query("select key, value from net.setting where key in ('tick_ms', 'gateway_tick', 'gateway_drain')", &[]).await {
                for r in rows {
                    let (k, v): (String, String) = (r.get(0), r.get(1));
                    match k.as_str() {
                        "tick_ms" => {
                            if let Ok(ms) = v.parse::<u64>() {
                                if (1..=1000).contains(&ms) {
                                    tick_ms = ms;
                                }
                            }
                        }
                        "gateway_tick" if valid_sql_call(&v) => tick_fn = v,
                        "gateway_drain" if valid_sql_call(&v) => drain_fn = v,
                        _ => {}
                    }
                }
            }
        }
        let period = Duration::from_millis(tick_ms);
        next += period;
        let now = Instant::now();
        let mut late = false;
        if now > next + period * 5 {
            next = now; // a long pause: do not try to catch up with a burst of ticks
            late = true;
        } else if now > next {
            late = true;
        }
        tokio::select! {
            _ = tokio::time::sleep_until(tokio::time::Instant::from_std(next)) => {}
            _ = &mut shutdown => {
                log::info!("shutting down");
                for (_, e) in conns.drain() {
                    let _ = e.handle.tx.try_send(Out::Close);
                }
                return Ok(());
            }
        }

        // ---- collect what happened since the last tick
        let mut new: Vec<(u64, String)> = Vec::new();
        let mut frames: Vec<(u64, Vec<u8>)> = Vec::new();
        let mut begun: Vec<i64> = Vec::new();
        let mut verdicts: Vec<(u64, Result<crate::mojang::Profile, AuthError>)> = Vec::new();
        let mut closed: Vec<i64> = Vec::new();
        while let Ok(e) = ev_rx.try_recv() {
            match e {
                Event::Connected { id, ip, handle } => {
                    conns.insert(id, Entry { handle });
                    new.push((id, ip));
                }
                Event::Frames { id, frames: fs } => {
                    if conns.contains_key(&id) {
                        for f in fs {
                            stats.frames_in += 1;
                            stats.bytes_in += f.len() as i64;
                            frames.push((id, f));
                        }
                    }
                }
                Event::KeyAccepted { id } => begun.push(id as i64),
                Event::Verdict { id, result } => verdicts.push((id, result)),
                Event::Closed { id, by_client } => {
                    conns.remove(&id);
                    if by_client {
                        closed.push(id as i64);
                    }
                }
            }
        }

        // ---- the database work of this tick, one transaction
        let t_db = Instant::now();
        let step = db_step(&mut client, &tick_fn, &drain_fn, last_ctl, &new, &frames, &begun, &verdicts, &closed).await;
        match step {
            Ok((drained, ctl, last)) => {
                last_ctl = last;
                stats.db_ms_sum += t_db.elapsed().as_secs_f64() * 1000.0;
                for (id, data, close) in drained {
                    let Some(e) = conns.get(&(id as u64)) else { continue };
                    if !data.is_empty() {
                        stats.frames_out += 1;
                        stats.bytes_out += data.len() as i64;
                        let pending = e.handle.shared.pending.fetch_add(data.len(), Ordering::Relaxed) + data.len();
                        if pending > ctx.cfg.max_pending_bytes || e.handle.tx.try_send(Out::Data(data)).is_err() {
                            let _ = e.handle.shared.kill.send(true); // the client cannot keep up: disconnected, as vanilla does
                            continue;
                        }
                    }
                    if close {
                        let _ = e.handle.tx.try_send(Out::Close);
                    }
                }
                for c in ctl {
                    let Some(e) = conns.get(&(c.conn_id as u64)) else { continue };
                    e.handle.shared.compression.store(c.compression, Ordering::Relaxed);
                    e.handle.shared.play.store(c.state == "play", Ordering::Relaxed);
                    if c.await_key {
                        if let (Some(token), Some(name)) = (c.token, c.name) {
                            *e.handle.shared.awaiting.lock().unwrap() = Some(Await { token, name });
                        }
                    }
                }
            }
            Err(e) => {
                // the transaction was rolled back: this tick's inbound frames are lost (a poison frame must not stall the server forever)
                log::error!("tick failed and was rolled back: {e}");
                stats.errors += 1;
            }
        }

        // ---- statistics, once a second (outside the tick transaction)
        let tick_ms_spent = t_db.elapsed().as_secs_f64() * 1000.0;
        stats.ticks += 1;
        stats.late += late as i32;
        stats.tick_ms_sum += tick_ms_spent;
        stats.tick_ms_max = stats.tick_ms_max.max(tick_ms_spent);
        if cfg.stats && stats_at.elapsed() >= Duration::from_secs(1) {
            let s = std::mem::take(&mut stats);
            stats_at = Instant::now();
            let n = s.ticks.max(1) as f64;
            let r = client
                .execute(
                    "insert into net.gateway_stats (ticks, late_ticks, tick_ms_avg, tick_ms_max, db_ms_avg, frames_in, bytes_in, frames_out, bytes_out, connections, rejected, errors) values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12) on conflict (ts) do nothing",
                    &[&s.ticks, &s.late, &(s.tick_ms_sum / n), &s.tick_ms_max, &(s.db_ms_sum / n), &s.frames_in, &s.bytes_in, &s.frames_out, &s.bytes_out, &(conns.len() as i32), &s.rejected, &s.errors],
                )
                .await;
            if let Err(e) = r {
                log::warn!("statistics: {e}");
            }
        }
        if sweep_at.elapsed() > Duration::from_secs(60) {
            sweep_at = Instant::now();
            ctx.limits.lock().unwrap().sweep();
            let _ = client.execute("delete from net.gateway_stats where ts < now() - interval '1 hour'", &[]).await;
        }
    }
}

struct CtlRow {
    conn_id: i64,
    state: String,
    compression: i32,
    await_key: bool,
    name: Option<String>,
    token: Option<Vec<u8>>,
}

#[allow(clippy::too_many_arguments)]
async fn db_step(
    client: &mut tokio_postgres::Client,
    tick_fn: &str,
    drain_fn: &str,
    last_ctl: i64,
    new: &[(u64, String)],
    frames: &[(u64, Vec<u8>)],
    begun: &[i64],
    verdicts: &[(u64, Result<crate::mojang::Profile, AuthError>)],
    closed: &[i64],
) -> Result<(Vec<(i64, Vec<u8>, bool)>, Vec<CtlRow>, i64), BoxErr> {
    let txn = client.transaction().await?;
    if !new.is_empty() {
        let ids: Vec<i64> = new.iter().map(|(i, _)| *i as i64).collect();
        let ips: Vec<String> = new.iter().map(|(_, ip)| ip.clone()).collect();
        txn.execute("select net.on_connect(c, i::inet) from unnest($1::bigint[], $2::text[]) as t(c, i)", &[&ids, &ips]).await?;
    }
    if !frames.is_empty() {
        let sink = txn.copy_in("COPY net.inbox (conn_id, payload) FROM STDIN BINARY").await?;
        let writer = BinaryCopyInWriter::new(sink, &[Type::INT8, Type::BYTEA]);
        pin_mut!(writer);
        for (id, f) in frames {
            let id = *id as i64;
            writer.as_mut().write(&[&id, &f.as_slice()]).await?;
        }
        writer.finish().await?;
    }
    if !begun.is_empty() {
        let b = begun.to_vec();
        txn.execute("select net.auth_begun($1::bigint[])", &[&b]).await?;
    }
    for (id, result) in verdicts {
        let id = *id as i64;
        match result {
            Ok(p) => {
                let props = serde_json::json!(p.properties.iter().map(|x| serde_json::json!({"name": x.name, "value": x.value, "signature": x.signature})).collect::<Vec<_>>());
                txn.execute("insert into net.auth_result (conn_id, ok, uuid, name, properties) values ($1, true, $2::text::uuid, $3, $4)", &[&id, &p.uuid, &p.name, &props]).await?;
            }
            Err(e) => {
                let reason = if *e == AuthError::Unavailable { "unavailable" } else { "invalid" };
                txn.execute("insert into net.auth_result (conn_id, ok, reason) values ($1, false, $2)", &[&id, &reason]).await?;
            }
        }
    }
    txn.execute("select net.apply_auth_results()", &[]).await?;
    txn.execute(format!("select {tick_fn}").as_str(), &[]).await?;
    if !closed.is_empty() {
        let c = closed.to_vec();
        txn.execute("select net.on_disconnect(c) from unnest($1::bigint[]) as t(c)", &[&c]).await?;
    }
    let drained: Vec<(i64, Vec<u8>, bool)> = txn
        .query(format!("select conn_id, data, close from {drain_fn}").as_str(), &[])
        .await?
        .into_iter()
        .map(|r| (r.get(0), r.get(1), r.get(2)))
        .collect();
    let mut last = last_ctl;
    let ctl: Vec<CtlRow> = txn
        .query("select conn_id, ctl_seq, state, compression, await_key, name, verify_token from net.gateway_ctl($1)", &[&last_ctl])
        .await?
        .into_iter()
        .map(|r| {
            let seq: i64 = r.get(1);
            last = last.max(seq);
            CtlRow { conn_id: r.get(0), state: r.get(2), compression: r.get(3), await_key: r.get(4), name: r.get(5), token: r.get(6) }
        })
        .collect();
    txn.commit().await?;
    Ok((drained, ctl, last))
}
