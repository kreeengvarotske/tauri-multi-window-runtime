//! Arm C: the catalog served through the preview revision pinned in Cargo.toml.
//!
//! The catalog with its indexes is the output of one `Shared` operation,
//! cached until the app exits; pages, totals and records are `View`s of it.
//! The commands are hand-written (runtime API decision 2) and are the same
//! three as in arm B, with the same request checks. What differs from B is
//! only the runtime around the data: registration, the cached operation, the
//! projection limit and the per-item response budget.

use crate::{
    catalog::{self, Catalog, CategoryTotal, Page, PageQuery, Record},
    workload,
};
use shared_runtime::{
    CachePolicy, CallError, CallOptions, Caller, OpContext, Operation, OperationConfig,
    ResponseBudget, Runtime, RuntimeConfig, View, ViewCallError, ViewError,
};
use std::{mem::size_of, time::Duration};

/// Most bytes one response may hold, as charged per item. A record holds at
/// most about 220 bytes (`catalog::record_bytes`), so 100 rows fit with room
/// to spare; a larger response would mean a bug, and is refused.
pub const MAX_RESPONSE_BYTES: usize = 64 * 1024;

/// Generates the catalog for this run's seed and size, and builds its
/// indexes. The parameters come from the command line, never from a window.
pub struct LoadCatalog {
    pub seed: u64,
    pub target_bytes: usize,
}

impl Operation for LoadCatalog {
    const NAME: &'static str = "catalog.load";
    type Params = ();
    type Output = Catalog;
    type Error = String;

    fn policy(&self) -> CachePolicy {
        CachePolicy::Forever
    }

    fn weight(&self, output: &Catalog) -> usize {
        output.data_bytes()
    }

    async fn run(&self, _ctx: OpContext, _params: ()) -> Result<Catalog, String> {
        let (seed, target) = (self.seed, self.target_bytes);
        tauri::async_runtime::spawn_blocking(move || Catalog::new(catalog::generate(seed, target)))
            .await
            .map_err(|error| format!("catalog generation failed: {error}"))
    }
}

/// One page over a prebuilt order.
pub struct PageView;

impl View<LoadCatalog> for PageView {
    const NAME: &'static str = "catalog.page";
    type Request = PageQuery;
    type Response = Page;

    fn source(&self, _request: &PageQuery) {}

    fn max_items(&self) -> usize {
        workload::PAGE_ROWS as usize
    }

    fn max_response_bytes(&self) -> usize {
        MAX_RESPONSE_BYTES
    }

    fn project(
        &self,
        output: &Catalog,
        query: PageQuery,
        budget: &mut ResponseBudget,
    ) -> Result<Page, ViewError> {
        let order = output.order(&query).ok_or_else(|| {
            ViewError::InvalidRequest("a category filter is sorted by price only".to_owned())
        })?;
        let positions = order
            .iter()
            .skip(query.offset as usize)
            .take(query.limit as usize);
        let mut rows = Vec::with_capacity(positions.len());
        for &position in positions {
            let record = output
                .record(position)
                .expect("an order holds positions of the catalog");
            budget.take(catalog::record_bytes(record))?;
            rows.push(record.clone());
        }
        Ok(Page {
            total: order.len() as u32,
            rows,
        })
    }

    fn items(page: &Page) -> usize {
        page.rows.len()
    }

    fn response_bytes(page: &Page) -> usize {
        page.rows.iter().map(catalog::record_bytes).sum()
    }
}

/// The per-category totals, computed once with the catalog.
pub struct AggregateView;

impl View<LoadCatalog> for AggregateView {
    const NAME: &'static str = "catalog.aggregate";
    type Request = ();
    type Response = Vec<CategoryTotal>;

    fn source(&self, _request: &()) {}

    fn max_items(&self) -> usize {
        usize::from(catalog::CATEGORIES)
    }

    fn max_response_bytes(&self) -> usize {
        MAX_RESPONSE_BYTES
    }

    fn project(
        &self,
        output: &Catalog,
        _request: (),
        budget: &mut ResponseBudget,
    ) -> Result<Vec<CategoryTotal>, ViewError> {
        let mut totals = Vec::with_capacity(output.totals().len());
        for total in output.totals() {
            budget.take(size_of::<CategoryTotal>())?;
            totals.push(*total);
        }
        Ok(totals)
    }

    fn items(totals: &Vec<CategoryTotal>) -> usize {
        totals.len()
    }

    fn response_bytes(totals: &Vec<CategoryTotal>) -> usize {
        totals.len() * size_of::<CategoryTotal>()
    }
}

/// Records by id (ids are positions); unknown ids are skipped, as in arm B.
pub struct GetView;

impl View<LoadCatalog> for GetView {
    const NAME: &'static str = "catalog.get";
    type Request = Vec<u32>;
    type Response = Vec<Record>;

    fn source(&self, _request: &Vec<u32>) {}

    fn max_items(&self) -> usize {
        workload::GET_IDS
    }

    fn max_response_bytes(&self) -> usize {
        MAX_RESPONSE_BYTES
    }

    fn project(
        &self,
        output: &Catalog,
        ids: Vec<u32>,
        budget: &mut ResponseBudget,
    ) -> Result<Vec<Record>, ViewError> {
        let mut records = Vec::with_capacity(ids.len().min(workload::GET_IDS));
        for id in ids {
            if let Some(record) = output.record(id) {
                budget.take(catalog::record_bytes(record))?;
                records.push(record.clone());
            }
        }
        Ok(records)
    }

    fn items(records: &Vec<Record>) -> usize {
        records.len()
    }

    fn response_bytes(records: &Vec<Record>) -> usize {
        records.iter().map(catalog::record_bytes).sum()
    }
}

/// The runtime's limits for this app. One operation and three views; every
/// window may build a response at the same time (`windows` projections),
/// and the cache holds the catalog with room for its estimate's error.
pub fn runtime_config(windows: u32, target_bytes: usize) -> RuntimeConfig {
    RuntimeConfig {
        max_concurrent_operations: 1,
        max_queued_operations: 4,
        max_concurrent_projections: windows.max(1) as usize,
        default_deadline: Duration::from_secs(10),
        shutdown_grace: Duration::from_secs(2),
        cache_budget_bytes: cache_budget_bytes(target_bytes),
    }
}

/// Twice the nominal size plus 16 MiB: the generator stops only after
/// passing the target, so the catalog's weight is a little above it.
pub fn cache_budget_bytes(target_bytes: usize) -> usize {
    target_bytes.saturating_mul(2).saturating_add(16 << 20)
}

pub fn build(seed: u64, windows: u32, target_bytes: usize) -> Runtime {
    Runtime::builder(runtime_config(windows, target_bytes))
        .and_then(|builder| {
            builder.register(
                LoadCatalog { seed, target_bytes },
                OperationConfig {
                    cache_budget_bytes: cache_budget_bytes(target_bytes),
                },
            )
        })
        .and_then(|builder| builder.view(PageView))
        .and_then(|builder| builder.view(AggregateView))
        .and_then(|builder| builder.view(GetView))
        .map(|builder| builder.build())
        .unwrap_or_else(|error| panic!("the arm C runtime is misconfigured: {error}"))
}

/// Loads the catalog into the runtime's cache before the windows open, as
/// arms A and B generate it at startup. Returns its record count and bytes.
pub async fn warm(runtime: &Runtime) -> Result<(u32, u64), String> {
    let operation = runtime
        .operation::<LoadCatalog>()
        .map_err(|error| error.to_string())?;
    let catalog = operation
        .get(&Caller::window("main"), (), CallOptions::default())
        .await
        .map_err(|error| call_error(&error))?;
    Ok((catalog.len() as u32, catalog.data_bytes() as u64))
}

/// The message a window receives for a failed call.
pub fn call_error<E: std::fmt::Display>(error: &CallError<E>) -> String {
    error.to_string()
}

pub fn view_error<E: std::fmt::Display>(error: ViewCallError<E>) -> String {
    match error {
        ViewCallError::Source(error) => call_error(&error),
        ViewCallError::DeadlineExceeded => "deadline exceeded".to_owned(),
        ViewCallError::View(error) => error.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::catalog::{Sort, reference_aggregate, reference_get, reference_page};

    fn block_on<F: std::future::Future>(future: F) -> F::Output {
        tauri::async_runtime::block_on(future)
    }

    #[test]
    fn views_match_the_reference_and_the_catalog_is_loaded_once() {
        let target = 512 * 1024;
        let runtime = build(7, 4, target);
        let (records, bytes) = block_on(warm(&runtime)).expect("warm-up");
        let reference = catalog::generate(7, target);
        assert_eq!(records as usize, reference.len());
        assert_eq!(bytes as usize, catalog::data_bytes(&reference));

        let pages = runtime.view::<LoadCatalog, PageView>().unwrap();
        let caller = Caller::window("w1");
        for query in [
            PageQuery {
                sort: Sort::Name,
                category: None,
                offset: 0,
                limit: 100,
            },
            PageQuery {
                sort: Sort::Price,
                category: None,
                offset: 300,
                limit: 100,
            },
            PageQuery {
                sort: Sort::Price,
                category: Some(5),
                offset: 0,
                limit: 100,
            },
            PageQuery {
                sort: Sort::Name,
                category: None,
                offset: records - 10,
                limit: 100,
            },
            PageQuery {
                sort: Sort::Name,
                category: None,
                offset: records + 10,
                limit: 100,
            },
        ] {
            let page = block_on(pages.get(&caller, query.clone(), CallOptions::default())).unwrap();
            assert_eq!(page, reference_page(&reference, &query), "{query:?}");
        }
        let totals = runtime.view::<LoadCatalog, AggregateView>().unwrap();
        assert_eq!(
            block_on(totals.get(&caller, (), CallOptions::default())).unwrap(),
            reference_aggregate(&reference)
        );
        let get = runtime.view::<LoadCatalog, GetView>().unwrap();
        let ids = vec![0, 17, records - 1, records + 5, 3];
        assert_eq!(
            block_on(get.get(&caller, ids.clone(), CallOptions::default())).unwrap(),
            reference_get(&reference, &ids)
        );

        let stats = runtime.stats();
        let load = stats.operation(LoadCatalog::NAME).unwrap();
        assert_eq!(
            load.executed, 1,
            "every window reads the one cached catalog"
        );
        assert_eq!((load.cache_entries, load.evictions, load.failed), (1, 0, 0));
        assert_eq!(load.requests, load.outcomes());
        assert!(stats.cache_weight_bytes() <= stats.allocated_budget_bytes());
    }

    #[test]
    fn views_refuse_what_the_service_refuses() {
        let runtime = build(1, 2, 64 * 1024);
        block_on(warm(&runtime)).unwrap();
        let caller = Caller::window("main");
        let pages = runtime.view::<LoadCatalog, PageView>().unwrap();
        let by_name_in_category = PageQuery {
            sort: Sort::Name,
            category: Some(1),
            offset: 0,
            limit: 10,
        };
        assert!(matches!(
            block_on(pages.get(&caller, by_name_in_category, CallOptions::default())),
            Err(ViewCallError::View(ViewError::InvalidRequest(_)))
        ));
        let too_long = PageQuery {
            sort: Sort::Name,
            category: None,
            offset: 0,
            limit: 101,
        };
        assert!(matches!(
            block_on(pages.get(&caller, too_long, CallOptions::default())),
            Err(ViewCallError::View(ViewError::TooManyItems {
                max_items: 100,
                ..
            }))
        ));
        let get = runtime.view::<LoadCatalog, GetView>().unwrap();
        assert!(matches!(
            block_on(get.get(&caller, (0..21).collect(), CallOptions::default())),
            Err(ViewCallError::View(ViewError::TooManyItems {
                max_items: 20,
                ..
            }))
        ));
    }

    #[test]
    fn a_page_is_charged_per_row_within_the_byte_limit() {
        let output = Catalog::new(catalog::generate(3, 256 * 1024));
        let query = PageQuery {
            sort: Sort::Price,
            category: None,
            offset: 0,
            limit: 100,
        };
        let mut budget = ResponseBudget::new(100, MAX_RESPONSE_BYTES);
        let page = PageView
            .project(&output, query.clone(), &mut budget)
            .unwrap();
        assert_eq!(budget.items(), 100);
        assert_eq!(budget.bytes(), PageView::response_bytes(&page));
        assert!(
            budget.bytes() < MAX_RESPONSE_BYTES / 2,
            "100 rows fit with room to spare"
        );

        let first = catalog::record_bytes(&page.rows[0]);
        let mut tight = ResponseBudget::new(100, first);
        assert!(matches!(
            PageView.project(&output, query, &mut tight),
            Err(ViewError::TooManyBytes { .. })
        ));
        assert_eq!(tight.items(), 1, "stops at the first row that does not fit");
    }

    #[test]
    fn the_cache_budget_holds_the_catalog_at_every_benchmark_size() {
        for mib in [0usize, 1, 16, 64] {
            let target = mib << 20;
            let weight = if mib > 16 {
                // Generating 64 MiB in a unit test is slow. `generate` stops at
                // the first record that reaches the target, so the weight is
                // below the target plus one record and its index entries
                // (under 300 bytes), whatever the size.
                target + 300
            } else {
                catalog::data_bytes(&catalog::generate(1, target))
            };
            assert!(weight <= cache_budget_bytes(target), "{mib} MiB");
        }
    }
}
