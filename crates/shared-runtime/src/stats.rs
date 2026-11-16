/// Counters of one operation. No keys, parameters, values or window labels.
/// The cache entry count, weight and evictions come from one snapshot.
/// Request counters can change while the snapshot is being collected.
///
/// Every counted call ends in exactly one terminal outcome, so once no call
/// is in flight:
///
/// `requests = cache_hits + executed + coalesced + overloaded
///             + deadline_exceeded + shutting_down + cancelled`
///
/// `executed` and `coalesced` count calls that received the operation's
/// result, a value or the operation's own error. `failed` is the subset of
/// calls that returned an error: operation errors (within `executed` and
/// `coalesced`) plus every `overloaded`, `deadline_exceeded` and
/// `shutting_down` call. `cancelled` calls were dropped by their caller and
/// returned nothing, so they are not in `failed`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OperationStats {
    pub name: &'static str,
    pub requests: u64,
    pub cache_hits: u64,
    pub executed: u64,
    pub coalesced: u64,
    pub overloaded: u64,
    pub deadline_exceeded: u64,
    pub shutting_down: u64,
    pub cancelled: u64,
    pub failed: u64,
    pub in_flight: u64,
    pub cache_entries: usize,
    pub cache_weight_bytes: usize,
    pub cache_budget_bytes: usize,
    pub evictions: u64,
}

impl OperationStats {
    /// Sum of the terminal outcomes; equals `requests` when nothing is in flight.
    pub fn outcomes(&self) -> u64 {
        self.cache_hits
            + self.executed
            + self.coalesced
            + self.overloaded
            + self.deadline_exceeded
            + self.shutting_down
            + self.cancelled
    }
}

/// Counters of every registered operation, in registration order.
///
/// Memory bound: `cache_weight_bytes() <= allocated_budget_bytes() <=
/// cache_budget_bytes`, because each operation's cached weight stays within
/// its own budget and the budgets were reserved from the runtime total.
/// Projection gauges are separate observations, not an atomic snapshot.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RuntimeStats {
    pub operations: Vec<OperationStats>,
    /// `RuntimeConfig::cache_budget_bytes`.
    pub cache_budget_bytes: usize,
    /// Projection slots in use or assigned to a waking waiter, through
    /// source lookup, projection and `get_with` serialization. At most
    /// `max_concurrent_projections`.
    pub active_projections: usize,
    /// View calls reserving/waiting for admission. At most
    /// `RuntimeConfig::max_queued_projections`; cancellation releases the seat.
    pub queued_projections: usize,
    /// View calls refused because the projection queue was full. They never
    /// request a source, so they are not in `OperationStats` request counters.
    pub projection_overloads: u64,
}

impl RuntimeStats {
    /// Summed weight of every operation's cached outputs.
    pub fn cache_weight_bytes(&self) -> usize {
        self.operations.iter().map(|op| op.cache_weight_bytes).sum()
    }

    /// Summed per-operation budgets reserved from `cache_budget_bytes`.
    pub fn allocated_budget_bytes(&self) -> usize {
        self.operations.iter().map(|op| op.cache_budget_bytes).sum()
    }

    pub fn operation(&self, name: &str) -> Option<&OperationStats> {
        self.operations.iter().find(|op| op.name == name)
    }
}
