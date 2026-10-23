use runtime_ipc::{IpcError, IpcErrorCode, ProjectMetadata, RuntimeDebugStats, RuntimeIpc};
use serde::Serialize;
use tauri::{State, WebviewWindow};

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InvalidateProjectResponse {
    pub invalidated: bool,
}

fn ensure_main_window(label: &str) -> Result<(), IpcError> {
    if label == "main" {
        Ok(())
    } else {
        Err(IpcError {
            code: IpcErrorCode::AccessDenied,
            message: "Only the main window may modify the runtime cache".to_owned(),
        })
    }
}

/// Returns cached or newly computed project metadata.
/// Both main and secondary windows may call this command.
#[tauri::command]
pub async fn runtime_get_project_metadata(
    project_id: String,
    runtime: State<'_, RuntimeIpc>,
) -> Result<ProjectMetadata, IpcError> {
    runtime.get_project_metadata(project_id).await
}

/// Returns a snapshot of the shared runtime statistics.
/// This read-only command does not count itself as a request.
#[tauri::command]
pub fn runtime_get_debug_stats(runtime: State<'_, RuntimeIpc>) -> RuntimeDebugStats {
    runtime.get_debug_stats()
}

/// Invalidates one project cache entry. The invoking window is identified
/// by Tauri itself, not by a caller-supplied JavaScript argument.
#[tauri::command]
pub fn runtime_invalidate_project(
    project_id: String,
    webview_window: WebviewWindow,
    runtime: State<'_, RuntimeIpc>,
) -> Result<InvalidateProjectResponse, IpcError> {
    ensure_main_window(webview_window.label())?;

    let invalidated = runtime.invalidate_project(project_id)?;
    Ok(InvalidateProjectResponse { invalidated })
}

/// Clears the shared cache. Only the actual Tauri window labelled "main"
/// is authorized, even if a frontend attempts to invoke this command manually.
#[tauri::command]
pub fn runtime_clear_cache(
    webview_window: WebviewWindow,
    runtime: State<'_, RuntimeIpc>,
) -> Result<(), IpcError> {
    ensure_main_window(webview_window.label())?;
    runtime.clear_cache();
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::ensure_main_window;
    use runtime_ipc::IpcErrorCode;

    #[test]
    fn main_window_may_modify_cache() {
        assert!(ensure_main_window("main").is_ok());
    }

    #[test]
    fn secondary_window_cannot_modify_cache() {
        let error = ensure_main_window("secondary").unwrap_err();
        assert_eq!(error.code, IpcErrorCode::AccessDenied);
    }

    #[test]
    fn unknown_window_cannot_modify_cache() {
        let error = ensure_main_window("unexpected").unwrap_err();
        assert_eq!(error.code, IpcErrorCode::AccessDenied);
    }
}
