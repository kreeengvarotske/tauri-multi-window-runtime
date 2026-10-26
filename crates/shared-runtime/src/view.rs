use std::fmt;

use crate::{CallError, Operation};

/// A bounded projection of an operation's output: a page, an aggregate, a
/// lookup. The output stays in Rust; only the response leaves the runtime.
pub trait View<O: Operation>: Send + Sync + 'static {
    const NAME: &'static str;
    type Request: Send;
    type Response: Send;

    /// Parameters of the source operation this request reads.
    fn source(&self, request: &Self::Request) -> O::Params;

    /// Most items one response may carry. The runtime refuses a larger
    /// response instead of truncating it silently.
    fn max_items(&self) -> usize;

    /// Most bytes one response may carry, as measured by `response_bytes`.
    /// The runtime checks this after response construction; it does not cap
    /// allocations made while building the response. Views must enforce a
    /// construction-time bound themselves. `max_items` alone does not bound
    /// bytes: one item can hold an arbitrarily long string.
    fn max_response_bytes(&self) -> usize;

    /// Builds the response. `max_items` is passed so that the view can
    /// clamp its own page size. The runtime checks the returned response's
    /// byte count after construction; this check does not prevent a view from
    /// allocating an oversized response first. Implementations must bound
    /// their output during construction (for example, clamp page sizes and
    /// string lengths).
    ///
    /// Must be cheap and bounded: work proportional to the response (at most
    /// `max_items` items), not to the whole output. It runs once per call,
    /// synchronously, under the runtime's projection limit. Sorting,
    /// indexing or scanning the whole output belong in the operation, whose
    /// result is cached and shared.
    fn project(
        &self,
        output: &O::Output,
        request: Self::Request,
        max_items: usize,
    ) -> Result<Self::Response, ViewError>;

    /// Items in a response, checked against `max_items`.
    fn items(response: &Self::Response) -> usize;

    /// Bytes the response holds (at least the sum of its variable-length
    /// fields), checked against `max_response_bytes`. It is the view's own
    /// measure; the adapter also bounds the serialized size it sends to the
    /// WebView.
    fn response_bytes(response: &Self::Response) -> usize;
}

/// Why a view returned nothing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ViewError {
    /// The request itself is invalid (bad offset, unknown sort key, …).
    InvalidRequest(String),
    /// The projection produced more than `max_items` items.
    TooManyItems { items: usize, max_items: usize },
    /// The projection holds more than `max_response_bytes` bytes.
    TooManyBytes { bytes: usize, max_bytes: usize },
}

impl fmt::Display for ViewError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidRequest(why) => write!(f, "invalid view request: {why}"),
            Self::TooManyItems { items, max_items } => {
                write!(f, "view response has {items} items, limit is {max_items}")
            }
            Self::TooManyBytes { bytes, max_bytes } => {
                write!(f, "view response has {bytes} bytes, limit is {max_bytes}")
            }
        }
    }
}

impl std::error::Error for ViewError {}

/// A view call fails while getting the source output, while waiting for a
/// projection slot, or in the view.
pub enum ViewCallError<E> {
    Source(CallError<E>),
    /// The caller's deadline passed while waiting for a projection slot.
    DeadlineExceeded,
    View(ViewError),
}

impl<E: fmt::Debug> fmt::Debug for ViewCallError<E> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Source(error) => f.debug_tuple("Source").field(error).finish(),
            Self::DeadlineExceeded => f.write_str("DeadlineExceeded"),
            Self::View(error) => f.debug_tuple("View").field(error).finish(),
        }
    }
}
