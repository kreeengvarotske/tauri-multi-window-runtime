// Every command needs a permission; capabilities/ grants them per window.
const COMMANDS: &[&str] = &["demo_catalog_page", "demo_window_note", "demo_stats"];

fn main() {
    let mut attributes = tauri_build::Attributes::new()
        .app_manifest(tauri_build::AppManifest::new().commands(COMMANDS));
    // tauri-build embeds its Windows manifest (Common Controls v6) into the
    // binary only. The IPC tests link the same Tauri code and fail to start
    // without it (STATUS_ENTRYPOINT_NOT_FOUND), so embed the manifest into
    // every target with the linker instead.
    if std::env::var("CARGO_CFG_TARGET_ENV").as_deref() == Ok("msvc") {
        attributes = attributes
            .windows_attributes(tauri_build::WindowsAttributes::new_without_app_manifest());
        let manifest =
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("windows-app-manifest.xml");
        println!("cargo:rerun-if-changed={}", manifest.display());
        println!("cargo:rustc-link-arg=/MANIFEST:EMBED");
        println!("cargo:rustc-link-arg=/MANIFESTINPUT:{}", manifest.display());
        println!("cargo:rustc-link-arg=/WX");
    }
    tauri_build::try_build(attributes).expect("failed to build Tauri application manifest");
}
