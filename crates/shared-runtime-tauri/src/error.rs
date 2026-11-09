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
/// Messages are safe to expose to the WebView. Every error the adapter maps
/// carries a fixed message for its class (`messages` below): no `Display` of
/// an operation error, a view's `InvalidRequest` text, a serde or parser
/// error, a registry error or a serialization error reaches the envelope,
/// because any of them can echo request content or private data. The only
/// numbers in a message are the command's configured byte limits. The code
/// says what happened; nothing about the request is logged.
///
/// Code outside this crate cannot put its own text in the envelope: the
/// fields are private and the only public constructor,
/// [`AdapterError::invalid_argument`], takes no message.
///
/// ```compile_fail
/// use shared_runtime_tauri::{AdapterError, AdapterErrorCode};
/// let _ = AdapterError::new(AdapterErrorCode::InvalidArgument, "app text");
/// ```
///
/// ```compile_fail
/// let mut error = shared_runtime_tauri::AdapterError::invalid_argument();
/// error.message = String::from("app text");
/// ```
///
/// ```
/// use shared_runtime_tauri::{AdapterError, AdapterErrorCode};
/// let error = AdapterError::invalid_argument();
/// assert_eq!(error.code(), AdapterErrorCode::InvalidArgument);
/// assert_eq!(error.message(), "invalid request");
/// ```
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AdapterError {
    code: AdapterErrorCode,
    message: String,
}

impl AdapterError {
    /// `message` is a fixed text from `messages`, or one that carries no more
    /// than a configured byte limit.
    pub(crate) fn new(code: AdapterErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }

    /// An application's own `INVALID_ARGUMENT`, with the same fixed message
    /// as a request the adapter refuses.
    pub fn invalid_argument() -> Self {
        Self::invalid_request()
    }

    pub fn code(&self) -> AdapterErrorCode {
        self.code
    }

    pub fn message(&self) -> &str {
        &self.message
    }

    pub(crate) fn invalid_request() -> Self {
        Self::new(AdapterErrorCode::InvalidArgument, messages::INVALID_REQUEST)
    }

    pub(crate) fn internal() -> Self {
        Self::new(AdapterErrorCode::Internal, messages::INTERNAL)
    }

    pub(crate) fn from_call<E>(error: CallError<E>) -> Self {
        match error {
            CallError::Operation(_) => Self::new(
                AdapterErrorCode::OperationFailed,
                messages::OPERATION_FAILED,
            ),
            CallError::DeadlineExceeded => Self::new(
                AdapterErrorCode::DeadlineExceeded,
                messages::DEADLINE_EXCEEDED,
            ),
            CallError::Overloaded => Self::new(AdapterErrorCode::Overloaded, messages::OVERLOADED),
            CallError::ShuttingDown => {
                Self::new(AdapterErrorCode::ShuttingDown, messages::SHUTTING_DOWN)
            }
        }
    }

    pub(crate) fn from_view_call<E>(error: ViewCallError<E>) -> Self {
        match error {
            ViewCallError::Source(error) => Self::from_call(error),
            ViewCallError::DeadlineExceeded => Self::new(
                AdapterErrorCode::DeadlineExceeded,
                messages::PROJECTION_DEADLINE_EXCEEDED,
            ),
            // The view's own text may quote the request; only the class leaves.
            ViewCallError::View(ViewError::InvalidRequest(_)) => Self::invalid_request(),
            ViewCallError::View(
                ViewError::TooManyItems { .. } | ViewError::TooManyBytes { .. },
            ) => Self::new(
                AdapterErrorCode::ResponseTooLarge,
                messages::RESPONSE_TOO_LARGE,
            ),
        }
    }
}

/// The fixed message of each error class the adapter maps.
pub(crate) mod messages {
    pub const INVALID_REQUEST: &str = "invalid request";
    pub const RESPONSE_TOO_LARGE: &str = "response is too large";
    pub const DEADLINE_EXCEEDED: &str = "deadline exceeded";
    pub const PROJECTION_DEADLINE_EXCEEDED: &str =
        "deadline exceeded waiting for a projection slot";
    pub const OVERLOADED: &str = "runtime overloaded";
    pub const SHUTTING_DOWN: &str = "runtime is shutting down";
    pub const OPERATION_FAILED: &str = "operation failed";
    pub const INTERNAL: &str = "internal error";
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
    fn runtime_outcomes_map_to_stable_envelopes() {
        let cases = [
            (
                CallError::Operation(Arc::new("disk full".to_owned())),
                "OPERATION_FAILED",
                "operation failed",
            ),
            (
                CallError::DeadlineExceeded,
                "DEADLINE_EXCEEDED",
                "deadline exceeded",
            ),
            (CallError::Overloaded, "OVERLOADED", "runtime overloaded"),
            (
                CallError::ShuttingDown,
                "SHUTTING_DOWN",
                "runtime is shutting down",
            ),
        ];
        for (error, code, message) in cases {
            assert_eq!(
                serde_json::to_value(AdapterError::from_call(error)).unwrap(),
                serde_json::json!({ "code": code, "message": message })
            );
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

    const SENTINEL: &str = "sentinel-7f3a9c";

    #[test]
    fn view_error_details_are_not_serialized_to_the_webview() {
        let cases = [
            (
                ViewCallError::<String>::View(ViewError::InvalidRequest(format!(
                    "unknown sort key {SENTINEL}"
                ))),
                AdapterErrorCode::InvalidArgument,
                messages::INVALID_REQUEST,
            ),
            (
                ViewCallError::View(ViewError::TooManyItems {
                    items: 7_313_377,
                    max_items: 1,
                }),
                AdapterErrorCode::ResponseTooLarge,
                messages::RESPONSE_TOO_LARGE,
            ),
            (
                ViewCallError::View(ViewError::TooManyBytes {
                    bytes: 7_313_377,
                    max_bytes: 1,
                }),
                AdapterErrorCode::ResponseTooLarge,
                messages::RESPONSE_TOO_LARGE,
            ),
            (
                ViewCallError::Source(CallError::Operation(Arc::new(SENTINEL.to_owned()))),
                AdapterErrorCode::OperationFailed,
                messages::OPERATION_FAILED,
            ),
        ];
        for (error, code, message) in cases {
            let error = AdapterError::from_view_call(error);
            let envelope = serde_json::to_string(&error).unwrap();
            assert_eq!((error.code, error.message.as_str()), (code, message));
            assert!(!envelope.contains(SENTINEL), "{envelope}");
            assert!(!envelope.contains("7313377"), "{envelope}");
        }
    }

    #[test]
    fn application_invalid_argument_does_not_carry_application_text() {
        // An application maps its own refusal, whose text quotes the request,
        // to INVALID_ARGUMENT; only the fixed message leaves.
        let parsed: Result<u32, String> = Err(format!("bad page token {SENTINEL}"));
        let error = parsed
            .map_err(|_| AdapterError::invalid_argument())
            .unwrap_err();
        let envelope = serde_json::to_string(&error).unwrap();

        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&envelope).unwrap(),
            serde_json::json!({ "code": "INVALID_ARGUMENT", "message": messages::INVALID_REQUEST })
        );
        assert!(!envelope.contains(SENTINEL), "{envelope}");
        assert_eq!(error, AdapterError::invalid_request());
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
