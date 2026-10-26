//! Memory benchmark scenario M (protocol: docs/benchmark/memory-pilot-protocol.md,
//! PR #33). One source; the arm is fixed at compile time:
//!
//! - arm A (no feature): every window loads the whole catalog once and keeps
//!   it in its JS heap; the backend generates it per call and keeps nothing;
//! - arm B (`shared`): a hand-written Rust service keeps one catalog with its
//!   indexes; windows request bounded pages, totals and records.
//!
//! Both arms run the same frontend, the same windows and the same workload.

pub mod catalog;
mod commands;
pub mod config;
pub mod coordinator;
pub mod workload;

use config::CatalogConfig;
use coordinator::Coordinator;
use tauri::{WebviewUrl, WebviewWindowBuilder};

pub fn run() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut config = match CatalogConfig::from_args(args.clone()) {
        Ok(config) => config,
        Err(error) => {
            eprintln!("catalog-bench: {error}");
            if let Some(path) = report_path(&args) {
                let report = serde_json::json!({ "schemaVersion": 1, "configError": error, "passed": false });
                let _ = std::fs::write(path, report.to_string());
            }
            std::process::exit(2);
        }
    };

    // Both arms generate the catalog once at startup, so that they do the
    // same work before the measured phases. Arm B keeps it; arm A drops it.
    let records = catalog::generate(config.seed, config.target_bytes());
    config.records = records.len() as u32;
    config.rust_data_bytes = catalog::data_bytes(&records) as u64;
    #[cfg(feature = "shared")]
    let shared = catalog::Catalog::new(records);
    #[cfg(not(feature = "shared"))]
    drop(records);

    let labels = config.labels();
    let builder = tauri::Builder::default()
        .manage(Coordinator::new(labels.clone()))
        .manage(config);
    #[cfg(feature = "shared")]
    let builder = builder.manage(shared);

    builder
        .setup(move |app| {
            for (index, label) in labels.iter().enumerate().skip(1) {
                WebviewWindowBuilder::new(app, label, WebviewUrl::App("index.html".into()))
                    .title(format!("Catalog Bench — {label}"))
                    .inner_size(720.0, 520.0)
                    .position(40.0 * index as f64, 40.0 * index as f64)
                    .build()?;
            }
            Ok(())
        })
        .invoke_handler(handler())
        .run(tauri::generate_context!())
        .expect("error while running the benchmark app");
}

#[cfg(not(feature = "shared"))]
fn handler() -> impl Fn(tauri::ipc::Invoke) -> bool + Send + Sync + 'static {
    tauri::generate_handler![
        commands::catalog_config,
        commands::catalog_ready,
        commands::catalog_begin,
        commands::catalog_plan,
        commands::catalog_workload,
        commands::catalog_load,
        commands::catalog_window_report,
        commands::catalog_collect,
        commands::catalog_write_report,
        commands::catalog_exit,
    ]
}

#[cfg(feature = "shared")]
fn handler() -> impl Fn(tauri::ipc::Invoke) -> bool + Send + Sync + 'static {
    tauri::generate_handler![
        commands::catalog_config,
        commands::catalog_ready,
        commands::catalog_begin,
        commands::catalog_plan,
        commands::catalog_workload,
        commands::catalog_page,
        commands::catalog_aggregate,
        commands::catalog_get,
        commands::catalog_window_report,
        commands::catalog_collect,
        commands::catalog_write_report,
        commands::catalog_exit,
    ]
}

fn report_path(args: &[String]) -> Option<&str> {
    args.windows(2)
        .find(|pair| pair[0] == "--report")
        .map(|pair| pair[1].as_str())
}
