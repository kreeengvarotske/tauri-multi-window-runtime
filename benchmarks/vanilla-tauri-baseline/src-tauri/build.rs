const COMMANDS: &[&str] = &[
    "baseline_get_project_metadata",
    "baseline_get_debug_stats",
];

fn main() {
    tauri_build::try_build(
        tauri_build::Attributes::new()
            .app_manifest(tauri_build::AppManifest::new().commands(COMMANDS)),
    )
    .expect("failed to build the Vanilla Tauri Baseline application manifest");
}
