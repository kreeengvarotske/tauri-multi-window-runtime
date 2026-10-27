use serde::Serialize;
use shared_runtime::{CallError, ViewCallError, ViewError};
use std::fmt;

/// Stable error codes of adapter commands.
///
/// The names are part of the command contract: they are never renamed or
/// reused for another meaning. New codes may be added. The demo IPC's
/// `runtime_ipc::IpcErrorCode` is separate and unchanged; the shared names
/// (`INVALID_ARGUMENT`, `OPERATION_FAILED`, `INTERNAL`) mean the same in both.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum AdapterErrorCode {
    /// The request is malformed, has unknown fields or values the command or
    /// view does not accept.
    InvalidArgument,
    /// The request body is larger than the command's limit. Nothing was
    /// deserialized.
    RequestTooLarge,
    /// The response would be larger than a limit: the view's item or byte
    /// limit, or the command's limit on serialized bytes. Nothing was sent.
    ResponseTooLarge,
    /// The caller's deadline passed, waiting for the operation or for a
    /// projection slot.
    DeadlineExceeded,
    /// No execution slot and the runtime's queue was full.
    Overloaded,
    /// The runtime is shutting down.
    ShuttingDown,
    /// The operation itself failed; the message is deliberately generic.
    OperationFailed,
    /// A bug in the application or adapter: an operation or view that is not
    /// registered, or a response that cannot be serialized.
    Internal,
}

impl AdapterErrorCode {
    /// The code as sent to the WebView.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::InvalidArgument => "INVALID_ARGUMENT",
            Self::RequestTooLarge => "REQUEST_TOO_LARGE",
            Self::ResponseTooLarge => "RESPONSE_TOO_LARGE",
            Self::DeadlineExceeded => "DEADLINE_EXCEEDED",
            Self::Overloaded => "OVERLOADED",
            Self::ShuttingDown => "SHUTTING_DOWN",
            Self::OperationFailed => "OPERATION_FAILED",
            Self::Internal => "INTERNAL",
        }
    }
}

/// The error a command returns: `{ "code": "...", "message": "..." }`, the
/// same envelope as the demo IPC.
///
/// Messages are safe to expose to the WebView. Operation failures use a
/// generic message so an operation's error details cannot disclose private
/// data through its `Display` implementation.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AdapterError {
    pub code: AdapterErrorCode,
    pub message: String,
}

impl AdapterError {
    pub fn new(code: AdapterErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }

    pub fn invalid_argument(message: impl Into<String>) -> Self {
        Self::new(AdapterErrorCode::InvalidArgument, message)
    }

    pub(crate) fn from_call<E>(error: CallError<E>) -> Self {
        match error {
            CallError::Operation(_) => {
                Self::new(AdapterErrorCode::OperationFailed, "operation failed")
            }
            CallError::DeadlineExceeded => {
                Self::new(AdapterErrorCode::DeadlineExceeded, "deadline exceeded")
            }
            CallError::Overloaded => Self::new(AdapterErrorCode::Overloaded, "runtime overloaded"),
            CallError::ShuttingDown => {
                Self::new(AdapterErrorCode::ShuttingDown, "runtime is shutting down")
            }
        }
    }

    pub(crate) fn from_view_call<E>(error: ViewCallError<E>) -> Self {
        match error {
            ViewCallError::Source(error) => Self::from_call(error),
            ViewCallError::DeadlineExceeded => Self::new(
                AdapterErrorCode::DeadlineExceeded,
                "deadline exceeded waiting for a projection slot",
            ),
            ViewCallError::View(ViewError::InvalidRequest(why)) => Self::invalid_argument(why),
            ViewCallError::View(error) => {
                Self::new(AdapterErrorCode::ResponseTooLarge, error.to_string())
            }
        }
    }
}

impl fmt::Display for AdapterError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.code.as_str(), self.message)
    }
}

impl std::error::Error for AdapterError {}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    /// The codes are a contract; this table changes only by adding rows.
    #[test]
    fn codes_are_stable() {
        let table = [
            (AdapterErrorCode::InvalidArgument, "INVALID_ARGUMENT"),
            (AdapterErrorCode::RequestTooLarge, "REQUEST_TOO_LARGE"),
            (AdapterErrorCode::ResponseTooLarge, "RESPONSE_TOO_LARGE"),
            (AdapterErrorCode::DeadlineExceeded, "DEADLINE_EXCEEDED"),
            (AdapterErrorCode::Overloaded, "OVERLOADED"),
            (AdapterErrorCode::ShuttingDown, "SHUTTING_DOWN"),
            (AdapterErrorCode::OperationFailed, "OPERATION_FAILED"),
            (AdapterErrorCode::Internal, "INTERNAL"),
        ];
        for (code, name) in table {
            assert_eq!(code.as_str(), name);
            assert_eq!(serde_json::to_value(code).unwrap(), name);
        }
    }

    #[test]
    fn envelope_is_code_and_message() {
        let error = AdapterError::new(AdapterErrorCode::Overloaded, "runtime overloaded");
        assert_eq!(
            serde_json::to_value(&error).unwrap(),
            serde_json::json!({ "code": "OVERLOADED", "message": "runtime overloaded" })
        );
    }

    #[test]
    fn runtime_outcomes_map_to_codes() {
        let cases: [(CallError<String>, AdapterErrorCode); 4] = [
            (
                CallError::Operation(Arc::new("disk full".to_owned())),
                AdapterErrorCode::OperationFailed,
            ),
            (
                CallError::DeadlineExceeded,
                AdapterErrorCode::DeadlineExceeded,
            ),
            (CallError::Overloaded, AdapterErrorCode::Overloaded),
            (CallError::ShuttingDown, AdapterErrorCode::ShuttingDown),
        ];
        for (error, code) in cases {
            assert_eq!(AdapterError::from_call(error).code, code);
        }
        let view = |error| AdapterError::from_view_call::<String>(ViewCallError::View(error)).code;
        assert_eq!(
            view(ViewError::InvalidRequest("bad offset".into())),
            AdapterErrorCode::InvalidArgument
        );
        assert_eq!(
            view(ViewError::TooManyItems {
                items: 2,
                max_items: 1
            }),
            AdapterErrorCode::ResponseTooLarge
        );
        assert_eq!(
            view(ViewError::TooManyBytes {
                bytes: 2,
                max_bytes: 1
            }),
            AdapterErrorCode::ResponseTooLarge
        );
        assert_eq!(
            AdapterError::from_view_call::<String>(ViewCallError::DeadlineExceeded).code,
            AdapterErrorCode::DeadlineExceeded
        );
    }

    #[test]
    fn operation_error_details_are_not_serialized_to_the_webview() {
        let error = AdapterError::from_call(CallError::Operation(Arc::new(
            "authentication token: secret-value".to_owned(),
        )));
        let envelope = serde_json::to_string(&error).unwrap();

        assert_eq!(error.code, AdapterErrorCode::OperationFailed);
        assert_eq!(error.message, "operation failed");
        assert!(!envelope.contains("secret-value"), "{envelope}");
    }
}
