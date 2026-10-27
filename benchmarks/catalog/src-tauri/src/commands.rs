//! Commands of the catalog app. Coordination commands exist in every arm;
//! data commands only in the arm they belong to (registered in `lib.rs`).

#[cfg(feature = "framework")]
use crate::framework;
use crate::{
    catalog,
    config::CatalogConfig,
    coordinator::{Coordinator, Plan},
    workload::{self, Workload},
};
use tauri::{AppHandle, State, WebviewWindow};

#[tauri::command]
pub fn catalog_config(config: State<'_, CatalogConfig>) -> CatalogConfig {
    config.inner().clone()
}

/// Called by each window once its page is set up (arm A: after loading and
/// indexing its own copy). Returns the windows ready so far.
#[tauri::command]
pub fn catalog_ready(
    coordinator: State<'_, Coordinator>,
    webview_window: WebviewWindow,
) -> Result<Vec<String>, String> {
    coordinator.mark_ready(webview_window.label())
}

/// Main only: computes every window's workload and expected checksums from a
/// fresh, transient copy of the catalog (the naive reference, not the
/// served path), then fixes the plan.
#[tauri::command]
pub async fn catalog_begin(
    config: State<'_, CatalogConfig>,
    coordinator: State<'_, Coordinator>,
    webview_window: WebviewWindow,
) -> Result<Plan, String> {
    ensure_main(&webview_window)?;
    if !coordinator.all_ready() {
        return Err("not every window is ready".to_owned());
    }
    let (seed, target) = (config.seed, config.target_bytes());
    let windows = config.windows;
    let workloads = tauri::async_runtime::spawn_blocking(move || {
        let records = catalog::generate(seed, target);
        (0..windows)
            .map(|index| workload::workload(&records, index))
            .collect::<Vec<Workload>>()
    })
    .await
    .map_err(|error| format!("expected checksums failed: {error}"))?;
    let plan = Plan::new(
        unix_ms(),
        config.idle_before_seconds,
        config.warmup_seconds,
        config.load_seconds,
        config.idle_after_seconds,
    );
    coordinator.begin(plan, |index| workloads[index as usize].clone())
}

#[tauri::command]
pub fn catalog_plan(coordinator: State<'_, Coordinator>) -> Option<Plan> {
    coordinator.plan()
}

#[tauri::command]
pub fn catalog_workload(
    coordinator: State<'_, Coordinator>,
    webview_window: WebviewWindow,
) -> Result<Workload, String> {
    coordinator.workload(webview_window.label())
}

/// Arm A: the whole catalog, generated for this call and not kept, as a
/// plain backend would read it from a file or database.
#[cfg(not(any(feature = "shared", feature = "framework")))]
#[tauri::command]
pub async fn catalog_load(
    config: State<'_, CatalogConfig>,
) -> Result<Vec<catalog::Record>, String> {
    let (seed, target) = (config.seed, config.target_bytes());
    tauri::async_runtime::spawn_blocking(move || catalog::generate(seed, target))
        .await
        .map_err(|error| format!("load failed: {error}"))
}

/// Arm B: one page from the shared catalog.
#[cfg(feature = "shared")]
#[tauri::command]
pub async fn catalog_page(
    query: catalog::PageQuery,
    shared: State<'_, catalog::Catalog>,
) -> Result<catalog::Page, String> {
    validate_page(&query)?;
    Ok(shared.page(&query))
}

#[cfg(feature = "shared")]
#[tauri::command]
pub async fn catalog_aggregate(
    shared: State<'_, catalog::Catalog>,
) -> Result<Vec<catalog::CategoryTotal>, String> {
    Ok(shared.aggregate())
}

#[cfg(feature = "shared")]
#[tauri::command]
pub async fn catalog_get(
    ids: Vec<u32>,
    shared: State<'_, catalog::Catalog>,
) -> Result<Vec<catalog::Record>, String> {
    if ids.len() > workload::GET_IDS {
        return Err(format!("at most {} ids per call", workload::GET_IDS));
    }
    Ok(shared.get(&ids))
}

/// Arm C: one page, through the runtime's page view. The same request
/// checks as arm B run first; the caller is the window Tauri identified.
#[cfg(feature = "framework")]
#[tauri::command]
pub async fn catalog_page(
    query: catalog::PageQuery,
    runtime: State<'_, shared_runtime::Runtime>,
    webview_window: WebviewWindow,
) -> Result<catalog::Page, String> {
    validate_page(&query)?;
    let view = runtime
        .view::<framework::LoadCatalog, framework::PageView>()
        .map_err(|error| error.to_string())?;
    view.get(&caller(&webview_window), query, Default::default())
        .await
        .map_err(framework::view_error)
}

#[cfg(feature = "framework")]
#[tauri::command]
pub async fn catalog_aggregate(
    runtime: State<'_, shared_runtime::Runtime>,
    webview_window: WebviewWindow,
) -> Result<Vec<catalog::CategoryTotal>, String> {
    let view = runtime
        .view::<framework::LoadCatalog, framework::AggregateView>()
        .map_err(|error| error.to_string())?;
    view.get(&caller(&webview_window), (), Default::default())
        .await
        .map_err(framework::view_error)
}

#[cfg(feature = "framework")]
#[tauri::command]
pub async fn catalog_get(
    ids: Vec<u32>,
    runtime: State<'_, shared_runtime::Runtime>,
    webview_window: WebviewWindow,
) -> Result<Vec<catalog::Record>, String> {
    if ids.len() > workload::GET_IDS {
        return Err(format!("at most {} ids per call", workload::GET_IDS));
    }
    let view = runtime
        .view::<framework::LoadCatalog, framework::GetView>()
        .map_err(|error| error.to_string())?;
    view.get(&caller(&webview_window), ids, Default::default())
        .await
        .map_err(framework::view_error)
}

#[cfg(feature = "framework")]
fn caller(webview_window: &WebviewWindow) -> shared_runtime::Caller {
    shared_runtime::Caller::window(webview_window.label())
}

/// The service's limits: bounded pages over the prebuilt orders only.
#[cfg_attr(not(any(feature = "shared", feature = "framework")), allow(dead_code))]
pub fn validate_page(query: &catalog::PageQuery) -> Result<(), String> {
    if query.limit == 0 || query.limit > workload::PAGE_ROWS {
        return Err(format!("limit must be 1 to {}", workload::PAGE_ROWS));
    }
    if query.offset > 100_000_000 {
        return Err("offset is out of range".to_owned());
    }
    match (query.category, query.sort) {
        (Some(c), _) if c >= catalog::CATEGORIES => Err("unknown category".to_owned()),
        (Some(_), catalog::Sort::Name) => {
            Err("a category filter is sorted by price only".to_owned())
        }
        _ => Ok(()),
    }
}

#[tauri::command]
pub fn catalog_window_report(
    report: String,
    coordinator: State<'_, Coordinator>,
    webview_window: WebviewWindow,
) -> Result<(), String> {
    coordinator.report(webview_window.label(), &report)
}

/// Main only: every window's report once all have reported, else `null`.
#[tauri::command]
pub fn catalog_collect(
    coordinator: State<'_, Coordinator>,
    webview_window: WebviewWindow,
) -> Result<Option<serde_json::Value>, String> {
    ensure_main(&webview_window)?;
    Ok(coordinator
        .collect()
        .ok()
        .map(|reports| serde_json::to_value(reports).unwrap_or_default()))
}

/// Writes the report to the path given on the command line. The page cannot
/// choose the path.
#[tauri::command]
pub fn catalog_write_report(
    report: String,
    config: State<'_, CatalogConfig>,
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

#[tauri::command]
pub fn catalog_exit(
    code: i32,
    app: AppHandle,
    config: State<'_, CatalogConfig>,
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

fn unix_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::validate_page;
    use crate::catalog::{PageQuery, Sort};

    #[test]
    fn page_queries_are_bounded() {
        let ok = PageQuery {
            sort: Sort::Name,
            category: None,
            offset: 0,
            limit: 100,
        };
        assert!(validate_page(&ok).is_ok());
        assert!(
            validate_page(&PageQuery {
                limit: 0,
                ..ok.clone()
            })
            .is_err()
        );
        assert!(
            validate_page(&PageQuery {
                limit: 101,
                ..ok.clone()
            })
            .is_err()
        );
        assert!(
            validate_page(&PageQuery {
                offset: 100_000_001,
                ..ok.clone()
            })
            .is_err()
        );
        assert!(
            validate_page(&PageQuery {
                sort: Sort::Price,
                category: Some(31),
                ..ok.clone()
            })
            .is_ok()
        );
        assert!(
            validate_page(&PageQuery {
                sort: Sort::Price,
                category: Some(32),
                ..ok.clone()
            })
            .is_err()
        );
        assert!(
            validate_page(&PageQuery {
                category: Some(1),
                ..ok
            })
            .is_err()
        );
    }
}
