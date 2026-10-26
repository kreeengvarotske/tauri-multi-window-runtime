// Every command needs a permission; capabilities/ grants them per window.
const COMMANDS: &[&str] = &["demo_catalog_page", "demo_window_note", "demo_stats"];

fn main() {
    tauri_build::try_build(
        tauri_build::Attributes::new()
            .app_manifest(tauri_build::AppManifest::new().commands(COMMANDS)),
    )
    .expect("failed to build Tauri application manifest");
}
