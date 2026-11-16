//! In-process runtime for Tauri applications.
//!
//! One [`Runtime`] per application holds typed [`Operation`]s. Their results
//! are cached and their concurrent calls coalesced in the Rust process, so
//! every window shares one copy of the data and one execution of the work.
//! Large outputs stay in Rust; windows read them through [`View`]s that
//! return bounded pages or aggregates.
//!
//! This crate has no Tauri dependency. A Tauri adapter builds a [`Caller`]
//! from the window Tauri identifies and exposes hand-written commands; the
//! WebView never reaches the runtime itself.
//!
//! Memory bounds, all set by the application:
//!
//! - cached outputs: `RuntimeConfig::cache_budget_bytes` for the whole
//!   runtime, split into per-operation `OperationConfig::cache_budget_bytes`
//!   reserved at registration (weights as estimated by `Operation::weight`);
//! - view responses: `View::max_items` (a count, not a byte bound) and
//!   `View::max_response_bytes` per response, charged item by item to a
//!   [`ResponseBudget`] before each item is built, and
//!   `RuntimeConfig::max_concurrent_projections` responses built at once.
//!   Transient response memory is therefore about `max_concurrent_projections
//!   × max_response_bytes` (plus each response's fixed fields) for views that
//!   charge before building, as `View::project` requires. The runtime
//!   cannot stop a view from allocating: one that builds first is refused
//!   by a check after the allocation, which is not a bound on peak memory;
//! - waiting views: `RuntimeConfig::max_queued_projections` calls may wait
//!   for admission. Excess calls return `CallError::Overloaded` before
//!   source parameter derivation. This is a count bound; requests, caller
//!   futures and IPC transport buffers need their own application limits;
//! - per-window outputs: dropped by [`Runtime::forget_window`] when the
//!   window closes; the runtime keeps no list of window labels;
//! - request and serialized response bytes on the IPC boundary: enforced by
//!   the adapter, before deserializing a request and after serializing a
//!   response, since only it sees the bytes.

mod config;
mod operation;
mod runtime;
mod stats;
mod view;

pub use config::{ConfigError, OperationConfig, RuntimeConfig};
pub use operation::{CallError, CallOptions, Caller, OpContext, Operation, ScopeRule};
pub use runtime::{OperationHandle, RegistryError, Runtime, RuntimeBuilder, ViewHandle};
pub use runtime_core::CachePolicy;
pub use stats::{OperationStats, RuntimeStats};
pub use view::{ResponseBudget, View, ViewCallError, ViewError};
