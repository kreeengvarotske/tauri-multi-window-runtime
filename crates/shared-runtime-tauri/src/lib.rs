//! Tauri v2 adapter for [`shared_runtime`].
//!
//! The runtime crate has no Tauri dependency; this crate is the only place
//! where Tauri meets it. It provides:
//!
//! - [`init`]: a plugin that stores one [`Runtime`](shared_runtime::Runtime)
//!   as Tauri state ([`SharedRuntime`]), calls
//!   [`Runtime::forget_window`](shared_runtime::Runtime::forget_window) when a
//!   window is destroyed and shuts the runtime down when the application
//!   exits;
//! - [`caller`]: the only way this adapter builds a
//!   [`Caller`](shared_runtime::Caller), from the window Tauri injects into a
//!   command;
//! - [`decode`]: request decoding that refuses an oversized body before any
//!   typed deserialization;
//! - [`SharedRuntime::view`] and [`SharedRuntime::call`]: run a view or an
//!   operation and serialize its response with a byte limit, the view inside
//!   the runtime's projection limit;
//! - [`AdapterError`]: the `{ code, message }` error envelope with stable
//!   codes.
//!
//! The adapter has no commands of its own. The application writes one
//! command per operation or view it exposes, and grants each one through
//! Tauri capabilities. There is no generic `call(op, params)` command: the
//! WebView never names an operation, a scope or a window.
//!
//! What the adapter guarantees and what it does not is listed in the
//! crate's README.

mod codec;
mod error;
mod plugin;
mod state;

pub use codec::{JsonBytes, decode, decode_body, encode_json};
pub use error::{AdapterError, AdapterErrorCode};
pub use plugin::{AdapterConfig, init};
pub use state::{SharedRuntime, caller};
