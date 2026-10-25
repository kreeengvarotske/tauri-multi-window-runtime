const COMMANDS: &[&str] = &[
    "bench_config",
    "bench_expected",
    "bench_run",
    "bench_stats",
    "bench_write_report",
    "bench_exit",
];

fn main() {
    tauri_build::try_build(
        tauri_build::Attributes::new()
            .app_manifest(tauri_build::AppManifest::new().commands(COMMANDS)),
    )
    .expect("failed to build Tauri application manifest");
}
