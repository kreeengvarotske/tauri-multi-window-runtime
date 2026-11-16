use std::{fmt, time::Duration};
use tokio::sync::Semaphore;

/// Limits for the whole runtime.
///
/// There is no `Default`: every limit is chosen by the application. Values
/// that suit one application (data size, window count, machine) can starve
/// or overload another, so they are measured, not assumed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RuntimeConfig {
    /// Operations that may execute at the same time, across all operations.
    /// Coalesced callers and cache hits do not take a slot.
    /// Must be between 1 and `Semaphore::MAX_PERMITS`, inclusive.
    pub max_concurrent_operations: usize,
    /// Executions that may wait for a slot. One more fails with `Overloaded`.
    pub max_queued_operations: usize,
    /// View calls admitted at the same time, from source lookup through
    /// projection and any `ViewHandle::get_with` callback. Waiting views
    /// retain no source output. This also limits the number of responses
    /// being built or serialized at once. At most `max_queued_projections`
    /// other calls wait, up to their own deadlines.
    /// Must be between 1 and `Semaphore::MAX_PERMITS`, inclusive.
    pub max_concurrent_projections: usize,
    /// View calls that may wait for projection admission across the runtime.
    /// A full queue returns `ViewCallError::Source(CallError::Overloaded)`.
    /// Zero allows immediate admission only. This bounds the number of
    /// waiting calls, not the bytes in their application-defined requests.
    pub max_queued_projections: usize,
    /// How long a caller waits when the call sets no deadline of its own.
    pub default_deadline: Duration,
    /// How long `shutdown` lets calls in flight finish before ending them.
    pub shutdown_grace: Duration,
    /// Upper bound on the summed weight of every operation's cached outputs.
    /// Each operation's `OperationConfig::cache_budget_bytes` is a sublimit
    /// carved out of it at registration; registration fails when the
    /// sublimits would add up to more than this.
    pub cache_budget_bytes: usize,
}

impl RuntimeConfig {
    pub(crate) fn validate(&self) -> Result<(), ConfigError> {
        if self.max_concurrent_operations == 0 {
            return Err(ConfigError("max_concurrent_operations must be at least 1"));
        }
        if self.max_concurrent_operations > Semaphore::MAX_PERMITS {
            return Err(ConfigError(
                "max_concurrent_operations exceeds the semaphore capacity",
            ));
        }
        if self.max_concurrent_projections == 0 {
            return Err(ConfigError("max_concurrent_projections must be at least 1"));
        }
        if self.max_concurrent_projections > Semaphore::MAX_PERMITS {
            return Err(ConfigError(
                "max_concurrent_projections exceeds the semaphore capacity",
            ));
        }
        if self.default_deadline.is_zero() {
            return Err(ConfigError("default_deadline must be greater than zero"));
        }
        Ok(())
    }
}

/// Limits for one registered operation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OperationConfig {
    /// This operation's share of `RuntimeConfig::cache_budget_bytes`: an upper
    /// bound on the summed `Operation::weight` of its cached outputs, with
    /// a minimum charge of one byte per entry. Zero disables caching for
    /// this operation. Least recently used outputs are evicted beyond the
    /// limit. Shares are reserved: one operation never evicts another's outputs.
    pub cache_budget_bytes: usize,
}

/// A limit that cannot work, reported when the runtime is built.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ConfigError(pub &'static str);

impl fmt::Display for ConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.0)
    }
}

impl std::error::Error for ConfigError {}
