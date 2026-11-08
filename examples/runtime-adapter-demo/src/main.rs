// Prevents an additional console window on Windows in release.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use runtime_adapter_demo::{DemoConfig, app, runtime, self_test};
use std::path::PathBuf;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let report = args
        .windows(2)
        .find(|pair| pair[0] == "--self-test")
        .map(|pair| PathBuf::from(&pair[1]));

    let runtime = runtime(DemoConfig::default()).expect("valid runtime configuration");
    let mut builder = app(tauri::Builder::default(), runtime);
    if report.is_some() {
        builder = builder.setup(|app| {
            self_test::start(app.handle().clone());
            Ok(())
        });
    }
    builder
        .build(tauri::generate_context!())
        .expect("error while building the demo")
        .run(move |app, event| {
            if let (Some(path), tauri::RunEvent::Exit) = (&report, &event) {
                self_test::finish(app, path);
            }
        });
}
