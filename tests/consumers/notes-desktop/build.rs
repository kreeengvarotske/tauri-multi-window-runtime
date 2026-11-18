fn main() {
    tauri_build::try_build(tauri_build::Attributes::new().app_manifest(
        tauri_build::AppManifest::new().commands(&["note", "finish", "qualification"]),
    ))
    .expect("notes consumer manifest");
}
