use runtime_ipc::{IpcError, IpcErrorCode, ProjectMetadata, RuntimeDebugStats, RuntimeIpc};
use serde::Serialize;
use tauri::{Emitter, State, WebviewWindow};

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InvalidateProjectResponse {
    pub invalidated: bool,
}

/// Broadcast to every window after the cache was invalidated or cleared.
pub const CACHE_INVALIDATED_EVENT: &str = "runtime://cache-invalidated";

/// Payload of [`CACHE_INVALIDATED_EVENT`]; `projectId` is `null` after a full clear.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CacheInvalidatedEvent {
    pub project_id: Option<String>,
}

/// Informs all windows. The cache has already changed at this point, so a
/// failed broadcast must not turn the command itself into an error.
fn notify_cache_invalidated(webview_window: &WebviewWindow, project_id: Option<String>) {
    let _ = webview_window.emit(
        CACHE_INVALIDATED_EVENT,
        CacheInvalidatedEvent { project_id },
    );
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

    let normalized = project_id.trim().to_owned();
    let invalidated = runtime.invalidate_project(project_id)?;
    notify_cache_invalidated(&webview_window, Some(normalized));
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
    notify_cache_invalidated(&webview_window, None);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{CacheInvalidatedEvent, ensure_main_window};
    use runtime_ipc::IpcErrorCode;

    #[test]
    fn cache_invalidated_event_serializes_as_camel_case() {
        let event = CacheInvalidatedEvent {
            project_id: Some("demo".to_owned()),
        };
        assert_eq!(
            serde_json::to_value(event).unwrap(),
            serde_json::json!({ "projectId": "demo" })
        );
        let cleared = CacheInvalidatedEvent { project_id: None };
        assert_eq!(
            serde_json::to_value(cleared).unwrap(),
            serde_json::json!({ "projectId": null })
        );
    }

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
