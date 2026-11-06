//! The logical workload of one window, the same in every arm, and its
//! expected checksums computed by the naive reference implementation.

use crate::catalog::{
    CATEGORIES, PageQuery, Record, Sort, aggregate_checksum, page_checksum, records_checksum,
    reference_aggregate, reference_get, reference_page,
};
use serde::Serialize;

/// Rows per page in the workload. Also the service's page limit.
pub const PAGE_ROWS: u32 = 100;
/// Ids per `get` step. Also the service's id limit.
pub const GET_IDS: usize = 20;

/// One step of the workload.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Step {
    Page(PageQuery),
    Aggregate,
    Get { ids: Vec<u32> },
}

/// One window's cycle of steps with the checksum each response must have.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Workload {
    pub window_index: u32,
    pub steps: Vec<Step>,
    pub expected: Vec<String>,
}

/// The cycle of window `window` over a catalog of `records` records:
/// open page 1 sorted by name, page forward 10 times, sort by price, filter
/// one category, read the per-category totals, read 20 records by id.
/// Windows start at different pages, filter different categories and read
/// different ids, so they do not request identical data in lockstep.
pub fn cycle(window: u32, records: u32) -> Vec<Step> {
    let base = if records == 0 {
        0
    } else {
        (window * 10 * PAGE_ROWS) % records / PAGE_ROWS * PAGE_ROWS
    };
    let mut steps: Vec<Step> = (0..11)
        .map(|k| {
            Step::Page(PageQuery {
                sort: Sort::Name,
                category: None,
                offset: base + k * PAGE_ROWS,
                limit: PAGE_ROWS,
            })
        })
        .collect();
    steps.push(Step::Page(PageQuery {
        sort: Sort::Price,
        category: None,
        offset: 0,
        limit: PAGE_ROWS,
    }));
    steps.push(Step::Page(PageQuery {
        sort: Sort::Price,
        category: Some((window as u16 * 7 + 3) % CATEGORIES),
        offset: 0,
        limit: PAGE_ROWS,
    }));
    steps.push(Step::Aggregate);
    let ids = if records == 0 {
        Vec::new()
    } else {
        (0..GET_IDS as u64)
            .map(|j| ((u64::from(window) * 7_919 + j * 104_729) % u64::from(records)) as u32)
            .collect()
    };
    steps.push(Step::Get { ids });
    steps
}

/// The checksum of the response to `step`, by the reference implementation.
pub fn expected(records: &[Record], step: &Step) -> String {
    match step {
        Step::Page(query) => page_checksum(&reference_page(records, query)),
        Step::Aggregate => aggregate_checksum(&reference_aggregate(records)),
        Step::Get { ids } => records_checksum(&reference_get(records, ids)),
    }
}

pub fn workload(records: &[Record], window: u32) -> Workload {
    let steps = cycle(window, records.len() as u32);
    let expected = steps.iter().map(|step| expected(records, step)).collect();
    Workload {
        window_index: window,
        steps,
        expected,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::catalog::{Catalog, generate};

    #[test]
    fn every_window_has_the_same_shape_of_cycle() {
        for records in [0, 1, 99, 5_000] {
            for window in 0..8 {
                let steps = cycle(window, records);
                assert_eq!(steps.len(), 15);
                let pages = steps.iter().filter(|s| matches!(s, Step::Page(_))).count();
                assert_eq!(pages, 13);
                assert!(matches!(steps[13], Step::Aggregate));
                match &steps[14] {
                    Step::Get { ids } => {
                        assert_eq!(ids.len(), if records == 0 { 0 } else { GET_IDS });
                        assert!(ids.iter().all(|&id| id < records.max(1)));
                    }
                    other => panic!("{other:?}"),
                }
            }
        }
        assert_ne!(cycle(0, 5_000), cycle(1, 5_000));
    }

    #[test]
    fn served_catalog_answers_every_step_with_the_expected_checksum() {
        let records = generate(11, 300 << 10);
        let catalog = Catalog::new(records.clone());
        for window in 0..4 {
            let workload = workload(&records, window);
            for (step, want) in workload.steps.iter().zip(&workload.expected) {
                let got = match step {
                    Step::Page(query) => page_checksum(&catalog.page(query)),
                    Step::Aggregate => aggregate_checksum(&catalog.aggregate()),
                    Step::Get { ids } => records_checksum(&catalog.get(ids)),
                };
                assert_eq!(&got, want, "window {window}, {step:?}");
            }
        }
    }

    #[test]
    fn steps_serialize_as_the_frontend_expects() {
        let json = serde_json::to_value(cycle(0, 1_000)).unwrap();
        assert_eq!(
            json[0],
            serde_json::json!({"kind": "page", "sort": "name", "category": null, "offset": 0, "limit": 100})
        );
        assert_eq!(json[13], serde_json::json!({"kind": "aggregate"}));
        assert_eq!(json[14]["kind"], "get");
    }
}

/// A small data set with every window's workload, shared with the frontend
/// tests so that arm A's local catalog is checked against the Rust reference.
#[cfg(test)]
mod fixture {
    use super::workload;
    use crate::catalog::generate;

    const PATH: &str = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../src/fixtures/catalog-small.json"
    );

    fn current() -> String {
        let records = generate(42, 48 << 10);
        let workloads: Vec<_> = (0..4).map(|w| workload(&records, w)).collect();
        let value = serde_json::json!({ "records": records, "workloads": workloads });
        serde_json::to_string_pretty(&value).unwrap() + "\n"
    }

    /// Run with `UPDATE_FIXTURE=1` to rewrite the file after a deliberate change.
    #[test]
    fn frontend_fixture_is_current() {
        let current = current();
        if std::env::var_os("UPDATE_FIXTURE").is_some() {
            std::fs::write(PATH, &current).unwrap();
        }
        let committed = std::fs::read_to_string(PATH)
            .unwrap_or_default()
            .replace("\r\n", "\n");
        assert!(
            committed == current,
            "{PATH} is stale; rerun with UPDATE_FIXTURE=1"
        );
    }
}
