mod commands;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .manage(runtime_ipc::RuntimeIpc::new_demo())
        .invoke_handler(tauri::generate_handler![
            commands::runtime_get_project_metadata,
            commands::runtime_get_debug_stats,
            commands::runtime_invalidate_project,
            commands::runtime_clear_cache,
        ])
        .run(tauri::generate_context!())
        .expect("error while running Tauri application");
}
