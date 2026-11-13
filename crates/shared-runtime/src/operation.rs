use runtime_core::CachePolicy;
use std::{fmt, future::Future, hash::Hash, sync::Arc, time::Duration};
use tokio::sync::watch;

use crate::runtime::Phase;

/// A typed, named unit of shared work.
///
/// Policy, scope and weight are fixed by the developer in Rust. Nothing a
/// window sends can change them.
pub trait Operation: Send + Sync + 'static {
    /// Unique name, e.g. `"catalog.load"`. Used in diagnostics.
    const NAME: &'static str;
    /// Already validated parameters; part of the cache key.
    type Params: Eq + Hash + Clone + Send + Sync + 'static;
    /// The result. It stays in the Rust process.
    type Output: Send + Sync + 'static;
    type Error: Send + Sync + 'static;

    fn policy(&self) -> CachePolicy;

    fn scope(&self) -> ScopeRule {
        ScopeRule::Shared
    }

    /// Approximate bytes `output` retains, counted against the cache budget.
    /// The runtime charges at least one byte per entry so empty outputs
    /// still consume a share of the budget.
    fn weight(&self, output: &Self::Output) -> usize;

    /// Produces the source output. An operation used by a view must not
    /// await a view on the same runtime, since the outer view holds a slot.
    fn run(
        &self,
        ctx: OpContext,
        params: Self::Params,
    ) -> impl Future<Output = Result<Self::Output, Self::Error>> + Send;
}

/// Who shares an operation's results.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScopeRule {
    /// One result for every window.
    Shared,
    /// One result per window, keyed by the window Tauri identified.
    ///
    /// This separates data between windows. It is not an access check: a
    /// window label says which window called, not what it may see.
    PerWindow,
}

/// The window a call comes from.
///
/// Only an adapter builds it, from the window Tauri itself injects into a
/// command; never from a value the frontend sends.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Caller {
    window: Arc<str>,
}

impl Caller {
    pub fn window(label: impl Into<Arc<str>>) -> Self {
        Self {
            window: label.into(),
        }
    }

    pub fn label(&self) -> &str {
        &self.window
    }

    pub(crate) fn window_key(&self) -> Arc<str> {
        Arc::clone(&self.window)
    }
}

/// Per-call options.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct CallOptions {
    /// How long this caller waits; `None` uses the runtime default. Reaching
    /// it ends this call only; other callers of the same execution keep
    /// waiting with their own deadlines. A zero duration refuses the call
    /// before cache lookup or execution. Synchronous work cannot be interrupted.
    pub deadline: Option<Duration>,
}

/// Passed to `Operation::run`.
#[derive(Clone)]
pub struct OpContext {
    pub(crate) phase: watch::Receiver<Phase>,
}

impl OpContext {
    /// `true` once the runtime has started to shut down. Long operations may
    /// check it between steps and return early.
    pub fn is_shutting_down(&self) -> bool {
        *self.phase.borrow() != Phase::Running
    }
}

/// Why a call returned no value.
pub enum CallError<E> {
    /// The operation's own error. Never cached; shared only with callers that
    /// joined the same execution before it finished.
    Operation(Arc<E>),
    /// This caller's deadline passed.
    DeadlineExceeded,
    /// No execution/admission slot and its queue was full.
    Overloaded,
    /// The runtime is shutting down.
    ShuttingDown,
}

impl<E> Clone for CallError<E> {
    fn clone(&self) -> Self {
        match self {
            Self::Operation(error) => Self::Operation(Arc::clone(error)),
            Self::DeadlineExceeded => Self::DeadlineExceeded,
            Self::Overloaded => Self::Overloaded,
            Self::ShuttingDown => Self::ShuttingDown,
        }
    }
}

impl<E: fmt::Debug> fmt::Debug for CallError<E> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Operation(error) => f.debug_tuple("Operation").field(error).finish(),
            Self::DeadlineExceeded => f.write_str("DeadlineExceeded"),
            Self::Overloaded => f.write_str("Overloaded"),
            Self::ShuttingDown => f.write_str("ShuttingDown"),
        }
    }
}

impl<E: fmt::Display> fmt::Display for CallError<E> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Operation(error) => write!(f, "operation failed: {error}"),
            Self::DeadlineExceeded => f.write_str("deadline exceeded"),
            Self::Overloaded => f.write_str("runtime overloaded"),
            Self::ShuttingDown => f.write_str("runtime is shutting down"),
        }
    }
}
