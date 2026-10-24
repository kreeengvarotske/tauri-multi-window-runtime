use serde::Serialize;
use std::{
    sync::atomic::{AtomicU64, Ordering},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tauri::State;

const DEMO_OPERATION_DELAY_MS: u64 = 400;

#[derive(Default)]
pub struct BaselineStats {
    requests_received: AtomicU64,
    operations_executed: AtomicU64,
    failed_requests: AtomicU64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectMetadata {
    pub project_id: String,
    pub name: String,
    pub revision: u32,
    pub computed_at_ms: u64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum CachePolicyDto {
    NoStore,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BaselineDebugStats {
    pub requests_received: u64,
    pub operations_executed: u64,
    pub coalesced_requests: u64,
    pub cache_hits: u64,
    pub failed_requests: u64,
    pub cached_entries: u64,
    pub cache_policy: CachePolicyDto,
}

#[tauri::command]
async fn baseline_get_project_metadata(
    project_id: String,
    stats: State<'_, BaselineStats>,
) -> Result<ProjectMetadata, String> {
    stats.requests_received.fetch_add(1, Ordering::Relaxed);

    let project_id = project_id.trim();
    if project_id.is_empty() || project_id.chars().count() > 128 {
        stats.failed_requests.fetch_add(1, Ordering::Relaxed);
        return Err("projectId must be non-empty and at most 128 characters".to_owned());
    }

    // Intentionally execute the provider once per invocation. This baseline has
    // no cache, in-flight operation map, or duplicate-request coalescing.
    stats.operations_executed.fetch_add(1, Ordering::Relaxed);
    tokio::time::sleep(Duration::from_millis(DEMO_OPERATION_DELAY_MS)).await;

    let (name, revision) = match project_id {
        "demo" => ("Demo project", 3),
        "project-42" => ("Project 42", 7),
        "alpha" => ("Alpha project", 1),
        "beta" => ("Beta project", 2),
        "flaky" => {
            stats.failed_requests.fetch_add(1, Ordering::Relaxed);
            return Err("The baseline provider was configured to fail".to_owned());
        }
        _ => {
            stats.failed_requests.fetch_add(1, Ordering::Relaxed);
            return Err("Project was not found".to_owned());
        }
    };

    Ok(ProjectMetadata {
        project_id: project_id.to_owned(),
        name: name.to_owned(),
        revision,
        computed_at_ms: unix_time_ms(),
    })
}

#[tauri::command]
fn baseline_get_debug_stats(stats: State<'_, BaselineStats>) -> BaselineDebugStats {
    BaselineDebugStats {
        requests_received: stats.requests_received.load(Ordering::Relaxed),
        operations_executed: stats.operations_executed.load(Ordering::Relaxed),
        coalesced_requests: 0,
        cache_hits: 0,
        failed_requests: stats.failed_requests.load(Ordering::Relaxed),
        cached_entries: 0,
        cache_policy: CachePolicyDto::NoStore,
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .manage(BaselineStats::default())
        .invoke_handler(tauri::generate_handler![
            baseline_get_project_metadata,
            baseline_get_debug_stats
        ])
        .run(tauri::generate_context!())
        .expect("error while running Vanilla Tauri Baseline");
}

fn unix_time_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(9_007_199_254_740_991) as u64
}

#[cfg(test)]
mod tests {
    use super::DEMO_OPERATION_DELAY_MS;

    #[test]
    fn baseline_operation_has_the_same_artificial_delay_as_runtime_demo() {
        assert_eq!(DEMO_OPERATION_DELAY_MS, 400);
    }
}
