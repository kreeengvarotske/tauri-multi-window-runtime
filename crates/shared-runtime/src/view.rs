use std::fmt;

use crate::{CallError, Operation};

/// A bounded projection of an operation's output: a page, an aggregate, a
/// lookup. The output stays in Rust; only the response leaves the runtime.
pub trait View<O: Operation>: Send + Sync + 'static {
    const NAME: &'static str;
    type Request: Send;
    type Response: Send;

    /// Parameters of the source operation this request reads.
    ///
    /// Called after reserving admission or a bounded queue position, before
    /// waiting for a projection slot, so a queued call can
    /// register its invalidation identity without retaining a source output.
    /// The runtime captures scope invalidation before this method starts;
    /// destroying a window or clearing while it runs cannot make its old
    /// call consume a newer cache generation.
    /// Keep this cheap: derive parameters only, without loading data. Cache
    /// lookup and operation execution still happen after admission.
    fn source(&self, request: &Self::Request) -> O::Params;

    /// Most items one response may carry. The runtime refuses a larger
    /// response instead of truncating it silently.
    fn max_items(&self) -> usize;

    /// Most bytes one response may carry, as charged to the budget and as
    /// measured by `response_bytes`. Bounds the size of the items, which
    /// `max_items` does not: one item can hold an arbitrarily long string.
    fn max_response_bytes(&self) -> usize;

    /// Builds the response within `budget`.
    ///
    /// Before building each item, the view charges it with
    /// [`ResponseBudget::take`] and, if that fails, stops and returns the
    /// error. So a response over the limits is refused after at most the
    /// items that fit were built, never built whole first. The runtime
    /// checks `items` and `response_bytes` again afterwards, but that check
    /// runs after the allocation: a view that builds first and charges
    /// later, or not at all, is refused without its memory being bounded.
    ///
    /// Must be cheap: work proportional to the response, not to the whole
    /// output. It runs once per call, synchronously, under the runtime's
    /// projection limit. Sorting, indexing or scanning the whole output
    /// belong in the operation, whose result is cached and shared.
    fn project(
        &self,
        output: &O::Output,
        request: Self::Request,
        budget: &mut ResponseBudget,
    ) -> Result<Self::Response, ViewError>;

    /// Items in a response, checked against `max_items`.
    fn items(response: &Self::Response) -> usize;

    /// Bytes the response holds (at least the sum of its variable-length
    /// fields), checked against `max_response_bytes`. It is the view's own
    /// measure; the adapter also bounds the serialized size it sends to the
    /// WebView.
    fn response_bytes(response: &Self::Response) -> usize;
}

/// What one response may still hold: items and bytes, from the view's
/// `max_items` and `max_response_bytes`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResponseBudget {
    max_items: usize,
    max_bytes: usize,
    items: usize,
    bytes: usize,
}

impl ResponseBudget {
    pub fn new(max_items: usize, max_bytes: usize) -> Self {
        Self {
            max_items,
            max_bytes,
            items: 0,
            bytes: 0,
        }
    }

    /// Charges one item of `bytes` before it is built. Fails, charging
    /// nothing, if the item would pass either limit; the view then stops.
    pub fn take(&mut self, bytes: usize) -> Result<(), ViewError> {
        if self.items >= self.max_items {
            return Err(ViewError::TooManyItems {
                items: self.items.saturating_add(1),
                max_items: self.max_items,
            });
        }
        if bytes > self.max_bytes - self.bytes {
            return Err(ViewError::TooManyBytes {
                bytes: self.bytes.saturating_add(bytes),
                max_bytes: self.max_bytes,
            });
        }
        self.items += 1;
        self.bytes += bytes;
        Ok(())
    }

    pub fn max_items(&self) -> usize {
        self.max_items
    }

    pub fn max_bytes(&self) -> usize {
        self.max_bytes
    }

    /// Items charged so far.
    pub fn items(&self) -> usize {
        self.items
    }

    /// Bytes charged so far.
    pub fn bytes(&self) -> usize {
        self.bytes
    }

    pub fn remaining_items(&self) -> usize {
        self.max_items - self.items
    }

    pub fn remaining_bytes(&self) -> usize {
        self.max_bytes - self.bytes
    }
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
/// projection slot, or in the view. A call refused or ended by shutdown is
/// `Source(CallError::ShuttingDown)`, as for the operation itself.
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
