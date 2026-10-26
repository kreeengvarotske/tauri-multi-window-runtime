/// Counters of one operation. No keys, parameters, values or window labels.
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
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RuntimeStats {
    pub operations: Vec<OperationStats>,
}

impl RuntimeStats {
    pub fn operation(&self, name: &str) -> Option<&OperationStats> {
        self.operations.iter().find(|op| op.name == name)
    }
}
