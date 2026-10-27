use serde::{Serialize, de::DeserializeOwned};
use std::io;
use tauri::ipc::{InvokeBody, InvokeResponseBody, IpcResponse, Request};

use crate::{AdapterError, AdapterErrorCode};

/// Decodes a command's request, refusing a body over `max_bytes` before any
/// typed deserialization.
///
/// The frontend sends the request as UTF-8 JSON bytes (`Uint8Array`), which
/// Tauri passes through unparsed on its custom-protocol IPC: the length is
/// checked first, then the bytes are parsed straight into `T`. If the body
/// arrives as JSON instead (an object argument, or Tauri's `postMessage`
/// fallback), Tauri has already parsed it; its serialized length is then
/// counted, without allocating, and checked before `T` is built from it.
///
/// Unknown fields are refused only if `T` says so
/// (`#[serde(deny_unknown_fields)]`), which command request types should.
pub fn decode<T: DeserializeOwned>(
    request: &Request<'_>,
    max_bytes: usize,
) -> Result<T, AdapterError> {
    decode_body(request.body(), max_bytes)
}

/// [`decode`] for a body on its own.
pub fn decode_body<T: DeserializeOwned>(
    body: &InvokeBody,
    max_bytes: usize,
) -> Result<T, AdapterError> {
    match body {
        InvokeBody::Raw(bytes) => {
            if bytes.len() > max_bytes {
                return Err(too_large_request(max_bytes));
            }
            serde_json::from_slice(bytes).map_err(invalid_request)
        }
        InvokeBody::Json(value) => {
            let mut counter = Limited::counter(max_bytes);
            match serde_json::to_writer(&mut counter, value) {
                Ok(()) => T::deserialize(value).map_err(invalid_request),
                Err(_) if counter.exceeded => Err(too_large_request(max_bytes)),
                Err(error) => Err(invalid_request(error)),
            }
        }
    }
}

fn too_large_request(max_bytes: usize) -> AdapterError {
    AdapterError::new(
        AdapterErrorCode::RequestTooLarge,
        format!("request body is larger than {max_bytes} bytes"),
    )
}

fn invalid_request(_error: serde_json::Error) -> AdapterError {
    // serde's message quotes unknown field names, variant names and parts of
    // the input, so it never reaches the envelope.
    AdapterError::invalid_request()
}

/// Serializes `value` as JSON for a command response, stopping as soon as the output would pass
/// `max_bytes`, so no more than `max_bytes` are ever buffered.
pub fn encode_json<T: Serialize>(value: &T, max_bytes: usize) -> Result<JsonBytes, AdapterError> {
    let mut writer = Limited::buffer(max_bytes);
    match serde_json::to_writer(&mut writer, value) {
        Ok(()) => Ok(JsonBytes(writer.buf)),
        Err(_) if writer.exceeded => Err(AdapterError::new(
            AdapterErrorCode::ResponseTooLarge,
            format!("serialized response is larger than {max_bytes} bytes"),
        )),
        // A `Serialize` impl's error text can carry the data it failed on.
        Err(_) => Err(AdapterError::internal()),
    }
}

/// A writer that fails once more than `max` bytes were written to it.
struct Limited {
    buf: Vec<u8>,
    written: usize,
    max: usize,
    keep: bool,
    exceeded: bool,
}

impl Limited {
    fn counter(max: usize) -> Self {
        Self {
            buf: Vec::new(),
            written: 0,
            max,
            keep: false,
            exceeded: false,
        }
    }

    fn buffer(max: usize) -> Self {
        Self {
            buf: Vec::with_capacity(max.min(4096)),
            written: 0,
            max,
            keep: true,
            exceeded: false,
        }
    }
}

impl io::Write for Limited {
    fn write(&mut self, data: &[u8]) -> io::Result<usize> {
        if data.len() > self.max - self.written {
            self.exceeded = true;
            return Err(io::Error::other("size limit exceeded"));
        }
        self.written += data.len();
        if self.keep {
            self.buf.extend_from_slice(data);
        }
        Ok(data.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

/// A serialized JSON response, sent to the WebView as raw bytes so that
/// Tauri does not serialize it again. The frontend decodes it with
/// `JSON.parse(new TextDecoder().decode(buffer))`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JsonBytes(Vec<u8>);

impl JsonBytes {
    pub fn as_bytes(&self) -> &[u8] {
        &self.0
    }

    pub fn len(&self) -> usize {
        self.0.len()
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

impl IpcResponse for JsonBytes {
    fn body(self) -> tauri::Result<InvokeResponseBody> {
        Ok(InvokeResponseBody::Raw(self.0))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::{Deserialize, Deserializer};
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[derive(Debug, Deserialize, PartialEq)]
    #[serde(deny_unknown_fields)]
    struct Page {
        offset: u32,
        limit: u32,
    }

    static DESERIALIZED: AtomicUsize = AtomicUsize::new(0);

    /// Counts every attempt to deserialize it.
    #[derive(Debug)]
    struct Counted;

    impl<'de> Deserialize<'de> for Counted {
        fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
            DESERIALIZED.fetch_add(1, Ordering::SeqCst);
            serde::de::IgnoredAny::deserialize(deserializer)?;
            Ok(Counted)
        }
    }

    fn raw(text: &str) -> InvokeBody {
        InvokeBody::Raw(text.as_bytes().to_vec())
    }

    #[test]
    fn raw_body_within_limit_decodes() {
        let body = raw(r#"{"offset":0,"limit":100}"#);
        assert_eq!(
            decode_body::<Page>(&body, 24).unwrap(),
            Page {
                offset: 0,
                limit: 100
            }
        );
    }

    #[test]
    fn oversized_raw_body_is_refused_before_deserialization() {
        let before = DESERIALIZED.load(Ordering::SeqCst);
        let body = InvokeBody::Raw(vec![b' '; 1 << 20]);
        let error = decode_body::<Counted>(&body, 1024).unwrap_err();
        assert_eq!(error.code, AdapterErrorCode::RequestTooLarge);
        assert_eq!(DESERIALIZED.load(Ordering::SeqCst), before);
        // One byte over the limit is refused too; exactly at it is not.
        let body = raw(r#"{"offset":0,"limit":100}"#);
        assert_eq!(
            decode_body::<Page>(&body, 23).unwrap_err().code,
            AdapterErrorCode::RequestTooLarge
        );
    }

    #[test]
    fn oversized_json_body_is_refused_before_typed_deserialization() {
        let before = DESERIALIZED.load(Ordering::SeqCst);
        let body = InvokeBody::Json(serde_json::json!({ "text": "x".repeat(4096) }));
        let error = decode_body::<Counted>(&body, 1024).unwrap_err();
        assert_eq!(error.code, AdapterErrorCode::RequestTooLarge);
        assert_eq!(DESERIALIZED.load(Ordering::SeqCst), before);
        let small = InvokeBody::Json(serde_json::json!({ "offset": 1, "limit": 2 }));
        assert_eq!(
            decode_body::<Page>(&small, 1024).unwrap(),
            Page {
                offset: 1,
                limit: 2
            }
        );
    }

    #[test]
    fn malformed_and_unknown_fields_are_invalid_arguments() {
        for text in [
            "{",
            "[]",
            r#"{"offset":0}"#,
            r#"{"offset":0,"limit":1,"window":"main"}"#,
        ] {
            let error = decode_body::<Page>(&raw(text), 1024).unwrap_err();
            assert_eq!(error.code, AdapterErrorCode::InvalidArgument, "{text}");
        }
    }

    const SENTINEL: &str = "sentinel-7f3a9c";

    #[test]
    fn invalid_requests_never_echo_the_request() {
        let bodies = [
            raw(&format!(r#"{{"offset":0,"limit":1,"{SENTINEL}":true}}"#)),
            raw(&format!(r#"{{"offset":"{SENTINEL}","limit":1}}"#)),
            raw(&format!(r#"{{"offset":0,"limit":1,"note":"{SENTINEL}"#)),
            raw(SENTINEL),
            InvokeBody::Json(serde_json::json!({ "offset": 0, "limit": 1, SENTINEL: 1 })),
            InvokeBody::Json(serde_json::json!({ "offset": SENTINEL, "limit": 1 })),
        ];
        for body in bodies {
            let error = decode_body::<Page>(&body, 1024).unwrap_err();
            let envelope = serde_json::to_string(&error).unwrap();
            assert_eq!(error.code, AdapterErrorCode::InvalidArgument, "{envelope}");
            assert_eq!(error.message, crate::error::messages::INVALID_REQUEST);
            assert!(!envelope.contains(SENTINEL), "{envelope}");
            assert!(!envelope.contains("offset"), "{envelope}");
        }
    }

    /// Fails to serialize with its secret in the error.
    struct Leaky;

    impl Serialize for Leaky {
        fn serialize<S: serde::Serializer>(&self, _serializer: S) -> Result<S::Ok, S::Error> {
            Err(serde::ser::Error::custom(format!(
                "cannot serialize {SENTINEL}"
            )))
        }
    }

    #[test]
    fn serialization_errors_never_reach_the_envelope() {
        let error = encode_json(&Leaky, 1024).unwrap_err();
        let envelope = serde_json::to_string(&error).unwrap();
        assert_eq!(error.code, AdapterErrorCode::Internal);
        assert_eq!(error.message, crate::error::messages::INTERNAL);
        assert!(!envelope.contains(SENTINEL), "{envelope}");
    }

    #[test]
    fn encode_stops_at_the_limit() {
        let value = vec!["x".repeat(100); 100];
        let full = serde_json::to_vec(&value).unwrap();
        assert_eq!(
            encode_json(&value, full.len()).unwrap().as_bytes(),
            full.as_slice()
        );
        let error = encode_json(&value, full.len() - 1).unwrap_err();
        assert_eq!(error.code, AdapterErrorCode::ResponseTooLarge);
    }
}
