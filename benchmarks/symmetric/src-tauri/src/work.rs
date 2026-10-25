//! The benchmark operation: deterministic CPU and memory work per key.

use serde::Serialize;
use std::hint::black_box;

/// Size and length of one execution, fixed for a whole run.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkParams {
    /// Working buffer allocated, filled and freed by every execution.
    pub buffer_mb: u32,
    /// Passes over the buffer; each pass depends on the previous one.
    pub iterations: u32,
}

impl Default for WorkParams {
    fn default() -> Self {
        Self {
            buffer_mb: 4,
            iterations: 100,
        }
    }
}

const WORDS_PER_MB: usize = (1 << 20) / std::mem::size_of::<u64>();

/// Runs the operation for `key` and returns its checksum.
///
/// The result depends only on `(key, params)`. Every pass reads the value
/// written by the previous step, so the work cannot be skipped or reordered,
/// and every page of the buffer is written. Only the checksum leaves the
/// function; the buffer is freed before it returns.
pub fn work(key: &str, params: WorkParams) -> u64 {
    let words = WORDS_PER_MB * params.buffer_mb as usize;
    let mut buffer = vec![0u64; words];
    let mut state = seed(key);
    for word in buffer.iter_mut() {
        state = splitmix64(state);
        *word = state;
    }
    let mut acc = state;
    for _ in 0..params.iterations {
        for word in buffer.iter_mut() {
            acc = splitmix64(acc ^ *word);
            *word = acc;
        }
    }
    black_box(&buffer);
    black_box(acc)
}

/// FNV-1a over the key bytes.
fn seed(key: &str) -> u64 {
    key.bytes().fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
        (hash ^ u64::from(byte)).wrapping_mul(0x0000_0100_0000_01b3)
    })
}

fn splitmix64(mut z: u64) -> u64 {
    z = z.wrapping_add(0x9e37_79b9_7f4a_7c15);
    z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
    z ^ (z >> 31)
}

#[cfg(test)]
mod tests {
    use super::{WorkParams, work};

    const SMALL: WorkParams = WorkParams {
        buffer_mb: 1,
        iterations: 2,
    };

    #[test]
    fn checksums_match_the_reference_values() {
        // Fixed once; a change here means the operation changed and earlier
        // results are no longer comparable.
        assert_eq!(work("key-0", SMALL), REFERENCE_KEY_0);
        assert_eq!(work("key-1", SMALL), REFERENCE_KEY_1);
        assert_eq!(
            work(
                "key-0",
                WorkParams {
                    buffer_mb: 2,
                    iterations: 1
                }
            ),
            REFERENCE_KEY_0_2MB_1
        );
    }

    #[test]
    fn result_depends_on_key_and_params() {
        assert_eq!(work("same", SMALL), work("same", SMALL));
        assert_ne!(work("a", SMALL), work("b", SMALL));
        assert_ne!(
            work("a", SMALL),
            work(
                "a",
                WorkParams {
                    buffer_mb: 1,
                    iterations: 3
                }
            )
        );
    }

    const REFERENCE_KEY_0: u64 = 15_713_329_323_001_000_635;
    const REFERENCE_KEY_1: u64 = 8_931_931_097_044_125_597;
    const REFERENCE_KEY_0_2MB_1: u64 = 14_142_053_531_319_042_490;
}
