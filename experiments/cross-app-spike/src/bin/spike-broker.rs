//! `spike-broker --endpoint <path|pipe> --manifest <file> [--op-delay-ms N]
//! [--idle-exit-ms N] [--checksum-ttl-ms N] [--hello-timeout-ms N]`
//!
//! Prints one JSON line `{"event":"listening",...}` once it accepts clients.
//! Exits with code 3 if another broker already owns the endpoint.

use cross_app_spike::broker::{Broker, BrokerConfig};
use cross_app_spike::identity::Manifest;
use cross_app_spike::transport::{self, Endpoint, Listener};
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Duration;

#[tokio::main]
async fn main() -> ExitCode {
    let mut endpoint = Endpoint::default_for_user();
    let mut manifest = None;
    let mut config_delay = Duration::ZERO;
    let mut idle_exit = None;
    let mut checksum_ttl = None;
    let mut hello_timeout = None;
    let mut args = std::env::args_os().skip(1);
    while let Some(flag) = args.next() {
        let value = args.next().unwrap_or_default();
        let number = || {
            value
                .to_string_lossy()
                .parse::<u64>()
                .map(Duration::from_millis)
        };
        match flag.to_str() {
            Some("--endpoint") => endpoint = Endpoint::new(value),
            Some("--manifest") => manifest = Some(PathBuf::from(value)),
            Some("--op-delay-ms") => config_delay = number().expect("--op-delay-ms"),
            Some("--idle-exit-ms") => idle_exit = Some(number().expect("--idle-exit-ms")),
            Some("--checksum-ttl-ms") => checksum_ttl = Some(number().expect("--checksum-ttl-ms")),
            Some("--hello-timeout-ms") => {
                hello_timeout = Some(number().expect("--hello-timeout-ms"))
            }
            _ => {
                eprintln!("unknown flag {flag:?}");
                return ExitCode::from(2);
            }
        }
    }
    let Some(manifest) = manifest else {
        eprintln!("--manifest is required");
        return ExitCode::from(2);
    };
    let manifest = match Manifest::load(&manifest) {
        Ok(manifest) => manifest,
        Err(err) => {
            eprintln!("cannot load manifest: {err}");
            return ExitCode::from(2);
        }
    };

    let mut config = BrokerConfig::new(manifest);
    config.op_delay = config_delay;
    if let Some(ttl) = checksum_ttl {
        config.checksum_ttl = ttl;
    }
    if let Some(timeout) = hello_timeout {
        config.hello_timeout = timeout;
    }

    let listener = match Listener::bind(&endpoint) {
        Ok(listener) => listener,
        Err(err) if transport::is_already_running(&err) => {
            println!("{}", serde_json::json!({"event": "alreadyRunning"}));
            return ExitCode::from(3);
        }
        Err(err) => {
            eprintln!("cannot bind {:?}: {err}", endpoint.0);
            return ExitCode::from(1);
        }
    };
    let broker = Broker::new(config);
    println!(
        "{}",
        serde_json::json!({"event": "listening", "instanceId": broker.instance_id(), "pid": std::process::id()})
    );
    match broker.serve(listener, idle_exit).await {
        Ok(()) => {
            println!("{}", serde_json::json!({"event": "idleExit"}));
            ExitCode::SUCCESS
        }
        Err(err) => {
            eprintln!("broker stopped: {err}");
            ExitCode::from(1)
        }
    }
}
