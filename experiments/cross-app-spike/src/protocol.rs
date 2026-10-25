//! Wire protocol of the spike: one JSON document per length-prefixed frame.
//!
//! Every message is strict (`deny_unknown_fields`): a client cannot smuggle a
//! `scope`, `isPublic` or `appId` field into a call. The only identity claim a
//! client makes is `Hello.appId`, and the broker treats it as a claim that it
//! must verify against the operating system (see `identity`).

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// The protocol version this build speaks.
pub const PROTOCOL_VERSION: u16 = 1;

/// Hard limit for a single frame in either direction.
pub const MAX_FRAME_BYTES: usize = 1 << 20;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum ClientMessage {
    /// Must be the first frame. `appId` is a claim, not proof.
    Hello {
        protocol_min: u16,
        protocol_max: u16,
        sdk: String,
        app_id: String,
    },
    Call {
        id: u64,
        op: String,
        op_version: u16,
        params: Value,
        /// Optional deadline; the broker caps it at its own maximum.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        deadline_ms: Option<u32>,
    },
    Cancel {
        id: u64,
    },
    /// Invalidates the caller's own view of one key. The scope is derived by
    /// the broker exactly as for `Call`.
    Invalidate {
        id: u64,
        op: String,
        op_version: u16,
        params: Value,
    },
    Stats {
        id: u64,
    },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum ServerMessage {
    Welcome {
        protocol: u16,
        broker_version: String,
        /// Changes on every broker start; results never cross instances.
        instance_id: String,
        /// The identity the broker verified, which may differ from nothing
        /// but the claim's spelling.
        app_id: String,
        max_frame_bytes: u32,
        max_in_flight: u32,
        operations: Vec<OperationDescriptor>,
    },
    /// Sent instead of `Welcome`; the broker closes the connection after it.
    Reject { code: ErrorCode, message: String },
    Result {
        id: u64,
        kind: RunKind,
        value: Value,
    },
    Error {
        id: u64,
        code: ErrorCode,
        message: String,
        retryable: bool,
    },
    /// A hint, never data: the client re-requests if it cares.
    Notice { event: NoticeEvent },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct OperationDescriptor {
    pub name: String,
    pub version: u16,
    pub scope: ScopeKind,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ScopeKind {
    /// Shared by every verified client that holds the grant.
    Public,
    /// Shared only between instances of the same verified application.
    App,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RunKind {
    Executed,
    Coalesced,
    CacheHit,
}

impl From<runtime_core::ServiceRunKind> for RunKind {
    fn from(kind: runtime_core::ServiceRunKind) -> Self {
        match kind {
            runtime_core::ServiceRunKind::Executed => Self::Executed,
            runtime_core::ServiceRunKind::Coalesced => Self::Coalesced,
            runtime_core::ServiceRunKind::CacheHit => Self::CacheHit,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum NoticeEvent {
    /// A key the receiver can read was invalidated. It carries no data.
    Invalidated {
        op: String,
        op_version: u16,
        scope: ScopeKind,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ErrorCode {
    HelloRequired,
    VersionMismatch,
    NotRegistered,
    IdentityMismatch,
    UnknownOperation,
    NotPermitted,
    InvalidParams,
    DuplicateId,
    Busy,
    FrameTooLarge,
    MalformedFrame,
    OperationFailed,
    Timeout,
    /// Produced by the client library when the connection is lost.
    BrokerUnavailable,
}

/// Picks the version both sides speak, or `None` if the ranges do not meet.
pub fn negotiate(client_min: u16, client_max: u16) -> Option<u16> {
    (client_min <= PROTOCOL_VERSION && PROTOCOL_VERSION <= client_max).then_some(PROTOCOL_VERSION)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn call_rejects_smuggled_scope_field() {
        let frame = json!({
            "type": "call", "id": 1, "op": "fixture.checksum", "opVersion": 1,
            "params": {"seed": 1, "sizeKib": 1}, "scope": "public"
        });
        assert!(serde_json::from_value::<ClientMessage>(frame).is_err());
    }

    #[test]
    fn messages_round_trip() {
        let hello = ClientMessage::Hello {
            protocol_min: 1,
            protocol_max: 1,
            sdk: "spike/0".into(),
            app_id: "demo.alpha".into(),
        };
        let text = serde_json::to_string(&hello).unwrap();
        assert!(text.contains("\"appId\""), "{text}");
        assert_eq!(serde_json::from_str::<ClientMessage>(&text).unwrap(), hello);

        let notice = ServerMessage::Notice {
            event: NoticeEvent::Invalidated {
                op: "fixture.checksum".into(),
                op_version: 1,
                scope: ScopeKind::Public,
            },
        };
        let text = serde_json::to_string(&notice).unwrap();
        assert_eq!(
            serde_json::from_str::<ServerMessage>(&text).unwrap(),
            notice
        );
    }

    #[test]
    fn negotiation_requires_overlap() {
        assert_eq!(negotiate(1, 1), Some(1));
        assert_eq!(negotiate(0, 3), Some(1));
        assert_eq!(negotiate(2, 3), None);
        assert_eq!(negotiate(0, 0), None);
    }
}
