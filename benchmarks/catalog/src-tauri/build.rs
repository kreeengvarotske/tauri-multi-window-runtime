const COMMANDS: &[&str] = &[
    "catalog_config",
    "catalog_ready",
    "catalog_begin",
    "catalog_plan",
    "catalog_workload",
    "catalog_load",
    "catalog_page",
    "catalog_aggregate",
    "catalog_get",
    "catalog_window_report",
    "catalog_collect",
    "catalog_write_report",
    "catalog_exit",
];

fn main() {
    tauri_build::try_build(
        tauri_build::Attributes::new()
            .app_manifest(tauri_build::AppManifest::new().commands(COMMANDS)),
    )
    .expect("failed to build Tauri application manifest");
}
