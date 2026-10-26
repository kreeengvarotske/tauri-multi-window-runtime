use shared_runtime::Runtime;
use std::time::Duration;
use tauri::{
    Manager, RunEvent, WindowEvent,
    plugin::{Builder, TauriPlugin},
};

use crate::SharedRuntime;

/// Adapter settings.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AdapterConfig {
    /// On exit the runtime gets its `shutdown_grace` for calls in flight to
    /// finish, then this long for the aborted ones to return, before the
    /// exit goes on regardless. Exit is therefore delayed by at most
    /// `shutdown_grace + abort_wait`.
    pub abort_wait: Duration,
}

/// The adapter plugin. It
///
/// - stores `runtime` as Tauri state ([`SharedRuntime`]), the one runtime of
///   the application;
/// - calls `forget_window` when Tauri reports a window destroyed, so that a
///   window opened later under the same label starts with no `PerWindow`
///   data;
/// - shuts the runtime down on `RunEvent::Exit`, waiting at most
///   `shutdown_grace + abort_wait`.
///
/// It registers no commands and needs no permissions.
pub fn init<R: tauri::Runtime>(runtime: Runtime, config: AdapterConfig) -> TauriPlugin<R> {
    Builder::<R, ()>::new("shared-runtime")
        .setup(move |app, _api| {
            app.manage(SharedRuntime::new(runtime, config.abort_wait));
            Ok(())
        })
        .on_event(|app, event| match event {
            RunEvent::WindowEvent {
                label,
                event: WindowEvent::Destroyed,
                ..
            } => {
                app.state::<SharedRuntime>().forget_window(label);
            }
            RunEvent::Exit => {
                let state = app.state::<SharedRuntime>();
                tauri::async_runtime::block_on(state.shutdown());
            }
            _ => {}
        })
        .build()
}
