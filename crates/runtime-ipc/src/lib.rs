use runtime_core::{CachePolicy, CachedService, ServiceRunKind};
use serde::Serialize;
use std::{
    sync::atomic::{AtomicU64, Ordering},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

/// Maximum integer that JavaScript can represent exactly.
pub const MAX_SAFE_INTEGER: u64 = 9_007_199_254_740_991;

/// Demo cache lifetime.
pub const CACHE_TTL_SECONDS: u64 = 30;

/// Artificial delay so concurrent requests can share one operation.
pub const DEMO_OPERATION_DELAY_MS: u64 = 400;

/// JSON representation of the cache policy.
///
/// The core remains independent of serde.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum CachePolicyDto {
    NoStore,
    Ttl { ttl_ms: u64 },
    Forever,
}

impl From<CachePolicy> for CachePolicyDto {
    fn from(policy: CachePolicy) -> Self {
        match policy {
            CachePolicy::NoStore => Self::NoStore,
            CachePolicy::Ttl(ttl) => Self::Ttl {
                ttl_ms: u64::try_from(ttl.as_millis())
                    .unwrap_or(u64::MAX)
                    .min(MAX_SAFE_INTEGER),
            },
            CachePolicy::Forever => Self::Forever,
        }
    }
}

/// Metadata returned by the demo provider.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectMetadata {
    pub project_id: String,
    pub name: String,
    pub revision: u32,
    pub computed_at_ms: u64,
}

/// Stable error codes exposed to the Tauri layer and TypeScript SDK.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum IpcErrorCode {
    InvalidArgument,
    ProjectNotFound,
    AccessDenied,
    OperationFailed,
    Internal,
}

/// Serializable error payload returned by IPC commands.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IpcError {
    pub code: IpcErrorCode,
    pub message: String,
}

impl IpcError {
    fn new(code: IpcErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }

    fn invalid_argument() -> Self {
        Self::new(
            IpcErrorCode::InvalidArgument,
            "projectId must be non-empty and at most 128 characters",
        )
    }
}

/// Snapshot of the IPC service's counters.
///
/// Calling `get_debug_stats` does not increment these counters.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeDebugStats {
    pub requests_received: u64,
    pub operations_executed: u64,
    pub coalesced_requests: u64,
    pub cache_hits: u64,
    pub failed_requests: u64,
    pub cached_entries: u64,
    pub cache_policy: CachePolicyDto,
}

#[derive(Default)]
struct AtomicRuntimeStats {
    requests_received: AtomicU64,
    operations_executed: AtomicU64,
    coalesced_requests: AtomicU64,
    cache_hits: AtomicU64,
    failed_requests: AtomicU64,
}

impl AtomicRuntimeStats {
    fn increment(counter: &AtomicU64) {
        // Keep counters within JavaScript's exact integer range. Use the long-
        // established compare-exchange API instead of fetch_update, which is
        // deprecated in newer Rust toolchains.
        let mut current = counter.load(Ordering::Relaxed);

        loop {
            if current >= MAX_SAFE_INTEGER {
                return;
            }

            match counter.compare_exchange_weak(
                current,
                current + 1,
                Ordering::Relaxed,
                Ordering::Relaxed,
            ) {
                Ok(_) => return,
                Err(actual) => current = actual,
            }
        }
    }

    fn snapshot(&self, cached_entries: usize, cache_policy: CachePolicy) -> RuntimeDebugStats {
        RuntimeDebugStats {
            requests_received: self.requests_received.load(Ordering::Relaxed),
            operations_executed: self.operations_executed.load(Ordering::Relaxed),
            coalesced_requests: self.coalesced_requests.load(Ordering::Relaxed),
            cache_hits: self.cache_hits.load(Ordering::Relaxed),
            failed_requests: self.failed_requests.load(Ordering::Relaxed),
            cached_entries: u64::try_from(cached_entries)
                .unwrap_or(u64::MAX)
                .min(MAX_SAFE_INTEGER),
            cache_policy: cache_policy.into(),
        }
    }
}

#[derive(Debug, Clone)]
enum DemoProjectError {
    NotFound,
    Failed,
}

impl From<&DemoProjectError> for IpcError {
    fn from(error: &DemoProjectError) -> Self {
        match error {
            DemoProjectError::NotFound => {
                Self::new(IpcErrorCode::ProjectNotFound, "Project was not found")
            }
            DemoProjectError::Failed => {
                Self::new(IpcErrorCode::OperationFailed, "The demo provider failed")
            }
        }
    }
}

/// IPC-facing service logic.
///
/// This type has no Tauri dependency. The Tauri command layer owns the
/// application state and is responsible for restricting administrative
/// commands such as cache invalidation to the `main` window.
pub struct RuntimeIpc {
    projects: CachedService<String, ProjectMetadata, DemoProjectError>,
    stats: AtomicRuntimeStats,
}

impl RuntimeIpc {
    /// Creates the demo service with a 30-second TTL.
    pub fn new_demo() -> Self {
        Self::with_cache_policy(CachePolicy::Ttl(Duration::from_secs(CACHE_TTL_SECONDS)))
    }

    /// Creates the service with an explicit policy.
    ///
    /// `new_demo` should normally be used by the demo application.
    pub fn with_cache_policy(policy: CachePolicy) -> Self {
        Self {
            projects: CachedService::new(policy),
            stats: AtomicRuntimeStats::default(),
        }
    }

    /// Validates a project ID, loads its metadata, and records statistics.
    ///
    /// Invalid IDs are rejected before `requestsReceived` is incremented.
    pub async fn get_project_metadata(
        &self,
        project_id: String,
    ) -> Result<ProjectMetadata, IpcError> {
        let project_id = normalize_project_id(&project_id)?;

        self.record_request();

        let key = project_id.clone();

        let outcome = self
            .projects
            .run_with_metadata(key, || async move { load_demo_project(project_id).await })
            .await;

        match outcome.kind {
            ServiceRunKind::CacheHit => {
                AtomicRuntimeStats::increment(&self.stats.cache_hits);
            }
            ServiceRunKind::Coalesced => {
                AtomicRuntimeStats::increment(&self.stats.coalesced_requests);
            }
            ServiceRunKind::Executed => {
                AtomicRuntimeStats::increment(&self.stats.operations_executed);
            }
        }

        match outcome.result {
            Ok(value) => Ok((*value).clone()),
            Err(error) => {
                AtomicRuntimeStats::increment(&self.stats.failed_requests);
                Err(IpcError::from(error.as_ref()))
            }
        }
    }

    /// Returns current statistics without counting the stats request itself.
    pub fn get_debug_stats(&self) -> RuntimeDebugStats {
        self.stats
            .snapshot(self.projects.cached_entries(), self.projects.policy())
    }

    /// Invalidates one project entry.
    ///
    /// The Tauri command wrapper must restrict this operation to the `main`
    /// window. This library method does not perform window authorization.
    pub fn invalidate_project(&self, project_id: String) -> Result<bool, IpcError> {
        let project_id = normalize_project_id(&project_id)?;
        Ok(self.projects.invalidate(&project_id))
    }

    /// Clears all cached project metadata.
    ///
    /// The Tauri command wrapper must restrict this operation to the `main`
    /// window. This library method does not perform window authorization.
    pub fn clear_cache(&self) {
        self.projects.clear();
    }

    fn record_request(&self) {
        AtomicRuntimeStats::increment(&self.stats.requests_received);
    }
}

impl Default for RuntimeIpc {
    fn default() -> Self {
        Self::new_demo()
    }
}

fn normalize_project_id(project_id: &str) -> Result<String, IpcError> {
    let normalized = project_id.trim();

    if normalized.is_empty() || normalized.chars().count() > 128 {
        return Err(IpcError::invalid_argument());
    }

    Ok(normalized.to_owned())
}

async fn load_demo_project(project_id: String) -> Result<ProjectMetadata, DemoProjectError> {
    tokio::time::sleep(Duration::from_millis(DEMO_OPERATION_DELAY_MS)).await;

    let (name, revision) = match project_id.as_str() {
        "demo" => ("Demo project", 3),
        "alpha" => ("Alpha project", 1),
        "beta" => ("Beta project", 2),
        "flaky" => return Err(DemoProjectError::Failed),
        _ => return Err(DemoProjectError::NotFound),
    };

    Ok(ProjectMetadata {
        project_id,
        name: name.to_owned(),
        revision,
        computed_at_ms: unix_time_ms(),
    })
}

fn unix_time_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(MAX_SAFE_INTEGER as u128) as u64
}

#[cfg(test)]
mod tests {
    use super::{
        CACHE_TTL_SECONDS, CachePolicyDto, IpcError, IpcErrorCode, ProjectMetadata, RuntimeIpc,
    };
    use runtime_core::CachePolicy;
    use std::time::Duration;

    #[test]
    fn cache_policy_serializes_as_camel_case() {
        let policy = CachePolicyDto::from(CachePolicy::Ttl(Duration::from_secs(CACHE_TTL_SECONDS)));

        assert_eq!(
            serde_json::to_value(policy).unwrap(),
            serde_json::json!({
                "kind": "ttl",
                "ttlMs": 30_000
            })
        );
    }

    #[test]
    fn error_code_serializes_in_screaming_snake_case() {
        let error = IpcError {
            code: IpcErrorCode::ProjectNotFound,
            message: "Project was not found".to_owned(),
        };

        assert_eq!(
            serde_json::to_value(error).unwrap(),
            serde_json::json!({
                "code": "PROJECT_NOT_FOUND",
                "message": "Project was not found"
            })
        );
    }

    #[tokio::test]
    async fn invalid_ids_are_rejected_before_counting_requests() {
        let runtime = RuntimeIpc::new_demo();

        let empty = runtime
            .get_project_metadata("   ".to_owned())
            .await
            .unwrap_err();

        let too_long = runtime
            .get_project_metadata("x".repeat(129))
            .await
            .unwrap_err();

        assert_eq!(empty.code, IpcErrorCode::InvalidArgument);
        assert_eq!(too_long.code, IpcErrorCode::InvalidArgument);

        let stats = runtime.get_debug_stats();
        assert_eq!(stats.requests_received, 0);
        assert_eq!(stats.failed_requests, 0);
    }

    #[tokio::test]
    async fn successful_requests_count_execution_and_cache_hit() {
        let runtime = RuntimeIpc::new_demo();

        let first = runtime
            .get_project_metadata("demo".to_owned())
            .await
            .unwrap();

        let second = runtime
            .get_project_metadata("demo".to_owned())
            .await
            .unwrap();

        assert_eq!(first, second);
        assert_eq!(first.name, "Demo project");

        let stats = runtime.get_debug_stats();
        assert_eq!(stats.requests_received, 2);
        assert_eq!(stats.operations_executed, 1);
        assert_eq!(stats.coalesced_requests, 0);
        assert_eq!(stats.cache_hits, 1);
        assert_eq!(stats.failed_requests, 0);
        assert_eq!(stats.cached_entries, 1);
    }

    #[tokio::test]
    async fn concurrent_requests_are_coalesced() {
        let runtime = RuntimeIpc::new_demo();

        let (first, second) = tokio::join!(
            runtime.get_project_metadata("alpha".to_owned()),
            runtime.get_project_metadata("alpha".to_owned()),
        );

        let first: ProjectMetadata = first.unwrap();
        let second: ProjectMetadata = second.unwrap();

        assert_eq!(first, second);

        let stats = runtime.get_debug_stats();
        assert_eq!(stats.requests_received, 2);
        assert_eq!(stats.operations_executed, 1);
        assert_eq!(stats.coalesced_requests, 1);
        assert_eq!(stats.cache_hits, 0);
        assert_eq!(stats.failed_requests, 0);
    }

    #[tokio::test]
    async fn errors_are_counted_but_not_cached() {
        let runtime = RuntimeIpc::new_demo();

        let first = runtime
            .get_project_metadata("missing".to_owned())
            .await
            .unwrap_err();

        let second = runtime
            .get_project_metadata("missing".to_owned())
            .await
            .unwrap_err();

        assert_eq!(first.code, IpcErrorCode::ProjectNotFound);
        assert_eq!(second.code, IpcErrorCode::ProjectNotFound);

        let stats = runtime.get_debug_stats();
        assert_eq!(stats.requests_received, 2);
        assert_eq!(stats.operations_executed, 2);
        assert_eq!(stats.failed_requests, 2);
        assert_eq!(stats.cached_entries, 0);
    }

    #[tokio::test]
    async fn invalidation_forces_recomputation() {
        let runtime = RuntimeIpc::new_demo();

        let first = runtime
            .get_project_metadata("beta".to_owned())
            .await
            .unwrap();

        assert!(runtime.invalidate_project("beta".to_owned()).unwrap());

        let second = runtime
            .get_project_metadata("beta".to_owned())
            .await
            .unwrap();

        assert_eq!(first.name, second.name);

        let stats = runtime.get_debug_stats();
        assert_eq!(stats.requests_received, 2);
        assert_eq!(stats.operations_executed, 2);
        assert_eq!(stats.cache_hits, 0);
        assert_eq!(stats.cached_entries, 1);
    }
}
