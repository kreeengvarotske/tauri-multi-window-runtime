const COMMANDS: &[&str] = &[
    "runtime_get_project_metadata",
    "runtime_get_debug_stats",
    "runtime_invalidate_project",
    "runtime_clear_cache",
];

fn main() {
    tauri_build::try_build(
        tauri_build::Attributes::new()
            .app_manifest(tauri_build::AppManifest::new().commands(COMMANDS)),
    )
    .expect("failed to build Tauri application manifest");
}
