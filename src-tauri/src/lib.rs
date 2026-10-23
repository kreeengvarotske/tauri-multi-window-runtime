// Rust Core is developed in a separate branch. Runtime commands
// (`runtime_get_project_metadata`, `runtime_get_debug_stats`) are registered here by Core.

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
