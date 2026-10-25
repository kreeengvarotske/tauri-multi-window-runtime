//! Symmetric benchmark app (issue #13, stage 9). One source, two builds:
//! without the `runtime` feature every request runs the operation; with it,
//! requests go through `runtime_core::CachedService`.

pub mod bench;
mod commands;
pub mod config;
pub mod work;

use bench::{Bench, Operation};
use config::BenchConfig;
use std::sync::Arc;

pub fn run() {
    let config = match BenchConfig::from_args(std::env::args().skip(1)) {
        Ok(config) => config,
        Err(error) => {
            eprintln!("symmetric-bench: {error}");
            std::process::exit(2);
        }
    };
    let params = config.work;
    let operation: Operation = Arc::new(move |key: &str| work::work(key, params));
    let bench = Bench::new(operation, config.scenario.ttl());

    tauri::Builder::default()
        .manage(config)
        .manage(bench)
        .invoke_handler(tauri::generate_handler![
            commands::bench_config,
            commands::bench_expected,
            commands::bench_run,
            commands::bench_stats,
            commands::bench_write_report,
            commands::bench_exit,
        ])
        .run(tauri::generate_context!())
        .expect("error while running the benchmark app");
}
