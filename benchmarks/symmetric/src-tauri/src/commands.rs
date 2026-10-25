use crate::{
    bench::{Bench, BenchStats, RunResponse},
    config::BenchConfig,
};
use tauri::{AppHandle, State, WebviewWindow};

/// Keys are short benchmark identifiers, never user data.
fn validate_key(key: &str) -> Result<(), String> {
    if key.is_empty() || key.len() > 64 {
        return Err("key must contain 1 to 64 characters".to_owned());
    }
    Ok(())
}

#[tauri::command]
pub fn bench_config(config: State<'_, BenchConfig>) -> BenchConfig {
    config.inner().clone()
}

#[tauri::command]
pub async fn bench_expected(key: String, bench: State<'_, Bench>) -> Result<String, String> {
    validate_key(&key)?;
    bench.expected(key).await
}

#[tauri::command]
pub async fn bench_run(key: String, bench: State<'_, Bench>) -> Result<RunResponse, String> {
    validate_key(&key)?;
    bench.run(key).await
}

#[tauri::command]
pub fn bench_stats(bench: State<'_, Bench>) -> BenchStats {
    bench.stats()
}

/// Writes the report to the path given on the command line. The page cannot
/// choose the path.
#[tauri::command]
pub fn bench_write_report(
    report: String,
    config: State<'_, BenchConfig>,
    webview_window: WebviewWindow,
) -> Result<(), String> {
    ensure_main(&webview_window)?;
    let path = config
        .report_path
        .as_ref()
        .ok_or_else(|| "no --report path was given".to_owned())?;
    std::fs::write(path, report)
        .map_err(|error| format!("cannot write {}: {error}", path.display()))
}

/// Ends an automated run once the report is written.
#[tauri::command]
pub fn bench_exit(
    code: i32,
    app: AppHandle,
    config: State<'_, BenchConfig>,
    webview_window: WebviewWindow,
) -> Result<(), String> {
    ensure_main(&webview_window)?;
    if !config.automated {
        return Err("only an automated run exits by itself".to_owned());
    }
    app.exit(code);
    Ok(())
}

fn ensure_main(webview_window: &WebviewWindow) -> Result<(), String> {
    if webview_window.label() == "main" {
        Ok(())
    } else {
        Err("only the main window may do this".to_owned())
    }
}

#[cfg(test)]
mod tests {
    use super::validate_key;

    #[test]
    fn keys_are_bounded() {
        assert!(validate_key("k").is_ok());
        assert!(validate_key("").is_err());
        assert!(validate_key(&"k".repeat(65)).is_err());
    }
}
