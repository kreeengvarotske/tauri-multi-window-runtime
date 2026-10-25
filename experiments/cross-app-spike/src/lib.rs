//! Cross-app shared service spike (non-normative).
//!
//! Two independently launched processes use one broker process through a
//! typed, versioned protocol over a per-user local endpoint. Only synthetic
//! data is used. See `docs/cross-app/` for the design this spike checks, and
//! `identity` for what is provisional.

pub mod broker;
pub mod client;
pub mod frame;
pub mod identity;
pub mod ops;
pub mod protocol;
pub mod transport;
