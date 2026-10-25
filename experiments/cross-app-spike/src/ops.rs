//! The typed operations the spike broker offers. All data is synthetic and
//! derived only from the parameters, so any result is safe to share inside
//! its scope.
//!
//! Each operation's parameter type is the cache key (together with the scope
//! the broker derives), so it must be `Hash + Eq` and strict about fields.

use crate::protocol::ScopeKind;
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use std::hash::Hash;

/// A typed operation, shared by the client library and the broker.
pub trait Operation {
    const NAME: &'static str;
    const VERSION: u16;
    const SCOPE: ScopeKind;
    type Params: Serialize + DeserializeOwned + Hash + Eq + Clone + Send + Sync + 'static;
    type Output: Serialize + DeserializeOwned + Send + 'static;
}

/// Largest synthetic buffer a call may ask for.
pub const MAX_SIZE_KIB: u32 = 16 * 1024;

/// Public: a checksum of a deterministic pseudo-random buffer.
pub struct Checksum;

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ChecksumParams {
    pub seed: u32,
    pub size_kib: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ChecksumOutput {
    pub seed: u32,
    pub size_kib: u32,
    pub checksum: String,
}

impl Operation for Checksum {
    const NAME: &'static str = "fixture.checksum";
    const VERSION: u16 = 1;
    const SCOPE: ScopeKind = ScopeKind::Public;
    type Params = ChecksumParams;
    type Output = ChecksumOutput;
}

/// App-scoped: a note whose text depends on the verified application. Two
/// applications asking for the same `n` must never share a result.
pub struct AppNote;

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AppNoteParams {
    pub n: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AppNoteOutput {
    pub app_id: String,
    pub n: u32,
    pub note: String,
}

impl Operation for AppNote {
    const NAME: &'static str = "fixture.appNote";
    const VERSION: u16 = 1;
    const SCOPE: ScopeKind = ScopeKind::App;
    type Params = AppNoteParams;
    type Output = AppNoteOutput;
}

/// Public: always fails, to show that errors are never cached or shared late.
pub struct Fail;

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct FailParams {
    pub code: u32,
}

impl Operation for Fail {
    const NAME: &'static str = "fixture.fail";
    const VERSION: u16 = 1;
    const SCOPE: ScopeKind = ScopeKind::Public;
    type Params = FailParams;
    type Output = serde_json::Value;
}

/// Deterministic checksum used by the broker and by tests as the oracle.
///
/// The buffer is materialised on purpose: it is the transient working memory
/// that a shared service would hold once instead of once per application.
pub fn checksum(params: &ChecksumParams) -> ChecksumOutput {
    let len = params.size_kib as usize * 1024;
    let mut state = u64::from(params.seed) ^ 0x9E37_79B9_7F4A_7C15;
    let mut buffer = Vec::with_capacity(len);
    while buffer.len() < len {
        // xorshift64
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        let bytes = state.to_le_bytes();
        let take = bytes.len().min(len - buffer.len());
        buffer.extend_from_slice(&bytes[..take]);
    }
    // FNV-1a 64
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in &buffer {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0100_0000_01b3);
    }
    ChecksumOutput {
        seed: params.seed,
        size_kib: params.size_kib,
        checksum: format!("{hash:016x}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn checksum_is_deterministic_and_seed_sensitive() {
        let a = checksum(&ChecksumParams {
            seed: 1,
            size_kib: 4,
        });
        let b = checksum(&ChecksumParams {
            seed: 1,
            size_kib: 4,
        });
        let c = checksum(&ChecksumParams {
            seed: 2,
            size_kib: 4,
        });
        assert_eq!(a, b);
        assert_ne!(a.checksum, c.checksum);
    }
}
