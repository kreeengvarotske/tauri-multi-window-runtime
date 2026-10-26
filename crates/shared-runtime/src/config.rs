use std::{fmt, time::Duration};

/// Limits for the whole runtime.
///
/// There is no `Default`: every limit is chosen by the application. Values
/// that suit one application (data size, window count, machine) can starve
/// or overload another, so they are measured, not assumed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RuntimeConfig {
    /// Operations that may execute at the same time, across all operations.
    /// Coalesced callers and cache hits do not take a slot.
    pub max_concurrent_operations: usize,
    /// Executions that may wait for a slot. One more fails with `Overloaded`.
    pub max_queued_operations: usize,
    /// How long a caller waits when the call sets no deadline of its own.
    pub default_deadline: Duration,
    /// How long `shutdown` lets calls in flight finish before ending them.
    pub shutdown_grace: Duration,
}

impl RuntimeConfig {
    pub(crate) fn validate(&self) -> Result<(), ConfigError> {
        if self.max_concurrent_operations == 0 {
            return Err(ConfigError("max_concurrent_operations must be at least 1"));
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
    /// Upper bound on the summed `Operation::weight` of this operation's
    /// cached outputs. Least recently used outputs are evicted beyond it.
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
