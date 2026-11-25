//! `pirc-gateway`, rewritten in Rust (docs/development/historical-records.md): the
//! central daemon. It authenticates browsers (forward auth), indexes
//! sessions, buffers their events and routes every session request to the
//! node that owns it. It never runs agents, terminals or workspace
//! inspection itself.

mod agent_ops;
mod app;
mod auth;
mod backends;
mod calendar;
mod capabilities;
mod checkpoints;
mod clients;
mod conversation_bindings;
mod conversation_submissions;
mod db;
mod devices;
mod dispatch;
mod error;
mod events;
mod features;
mod hints;
mod http;
mod log;
mod management;
mod memory;
mod memory_records;
mod node_events;
mod nodes;
mod pots;
mod push;
mod request_shape;
mod response_types;
mod routes;
mod schedules;
mod slots;
mod sockets;
#[cfg(test)]
mod test_support;
mod upload_references;
mod usage;
mod util;
mod web_search;
mod workspace_removal;
mod ws;

use std::net::SocketAddr;
use std::process::ExitCode;
use std::sync::Arc;

use pirc_config::{Env, GatewayConfig};

use crate::db::{Db, Store};

const USAGE: &str = "Usage: pirc-gateway [--help | --version | modes --print-defaults]\n\nStarts the gateway with no arguments. Configuration is read from the environment.\n";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.as_slice() == ["modes", "--print-defaults"] {
        for (name, text) in pirc_config::modes::DEFAULT_MODE_FILES {
            println!("# {name}\n{text}");
        }
        return ExitCode::SUCCESS;
    }
    if args.len() > 1 {
        eprint!("Unknown argument: {}\n\n{USAGE}", args[1]);
        return ExitCode::from(2);
    }
    match args.first().map(String::as_str) {
        Some("version" | "--version") => {
            println!("{}", env!("CARGO_PKG_VERSION"));
            return ExitCode::SUCCESS;
        }
        Some("help" | "--help" | "-h") => {
            print!("{USAGE}");
            return ExitCode::SUCCESS;
        }
        Some(other) => {
            eprint!("Unknown command: {other}\n\n{USAGE}");
            return ExitCode::from(2);
        }
        None => {}
    }
    let config = match GatewayConfig::load(&Env::from_process()) {
        Ok(config) => config,
        Err(error) => {
            eprintln!("pirc-gateway: {error}");
            return ExitCode::FAILURE;
        }
    };
    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(error) => {
            eprintln!("pirc-gateway: cannot start the runtime: {error}");
            return ExitCode::FAILURE;
        }
    };
    match runtime.block_on(run(config)) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("pirc-gateway: {error}");
            ExitCode::FAILURE
        }
    }
}

async fn run(config: GatewayConfig) -> Result<(), String> {
    let env = Env::from_process();
    pirc_config::registry::register_gateway(&config, &env)
        .map_err(|error| format!("cannot register gateway private directories: {error}"))?;
    let default_database = config.state_dir.join("gateway.sqlite");
    if default_database != config.database_path {
        db::refuse_earlier_database(&default_database)?;
    }
    let db = Arc::new(Db::open(&config.database_path)?);
    let recovery = db
        .lock()
        .recover_startup()
        .map_err(|error| format!("startup recovery: {error}"))?;
    log::info(&format!(
        "daemon startup recovery complete: {}",
        serde_json::to_string(&recovery).unwrap_or_default()
    ));
    if config.auth.proxy_secret.is_none() {
        log::warn(
            "PIRC_PROXY_SECRET_REQUIRED=false: running without a proxy secret, so any process that \
             can reach the gateway port from a trusted proxy address (PIRC_TRUSTED_PROXIES) can \
             claim to be any allowed user. Use this only for development.",
        );
    }
    // An invalid models file at startup is fatal; a missing one means no providers.
    let models = pirc_providers::load_models_file(
        &config.models_file,
        &|name| env.get(name).map(str::to_owned),
        &env.home(),
    )?
    .unwrap_or_else(app::empty_models);
    let backends = pirc_providers::backends::BackendService::open(&config.state_dir, models)?;
    let (host, port) = (config.host.clone(), config.port);
    pirc_config::modes::initialize_modes(&config.modes_dir).map_err(|e| e.to_string())?;
    let catalog = pirc_config::modes::load_modes(&config.modes_dir).map_err(|e| e.to_string())?;
    for warning in &catalog.warnings {
        log::warn(&warning.to_string());
    }
    let app = app::App::try_new(config, db, backends, catalog).map_err(|e| e.to_string())?;
    // Everything that can refuse to start does so before the port is bound.
    features::start(&app)?;
    app.devices.start_sweeper();
    conversation_submissions::start_cleanup(&app);
    conversation_bindings::transitions::start_recovery(&app);
    let listener = tokio::net::TcpListener::bind((host.as_str(), port))
        .await
        .map_err(|error| format!("cannot listen on {}:{}: {error}", host, port))?;
    let address = listener
        .local_addr()
        .map_err(|error| format!("listener address: {error}"))?;
    tokio::spawn(reload_on_hangup(app.clone()));
    log::info(&format!("listening on http://{address}"));
    axum::serve(
        listener,
        app::router(app.clone()).into_make_service_with_connect_info::<SocketAddr>(),
    )
    .with_graceful_shutdown({
        let app = app.clone();
        async move {
            shutdown().await;
            app.backends.close();
            app.inference.cancel_all();
            app.nodes.close_all();
        }
    })
    .await
    .map_err(|error| format!("server failed: {error}"))
}

/// SIGHUP reloads model and mode catalogs independently.
async fn reload_on_hangup(app: app::AppState) {
    use tokio::signal::unix::{SignalKind, signal};
    let Ok(mut hangup) = signal(SignalKind::hangup()) else {
        return;
    };
    while hangup.recv().await.is_some() {
        log::info("SIGHUP: reloading models and modes");
        app.reload_models();
        app.reload_modes();
    }
}

/// SIGINT or SIGTERM.
async fn shutdown() {
    use tokio::signal::unix::{SignalKind, signal};
    let (Ok(mut interrupt), Ok(mut terminate)) = (
        signal(SignalKind::interrupt()),
        signal(SignalKind::terminate()),
    ) else {
        return std::future::pending().await;
    };
    let name = tokio::select! {
        _ = interrupt.recv() => "SIGINT",
        _ = terminate.recv() => "SIGTERM",
    };
    log::info(&format!("{name}: shutting down"));
}
