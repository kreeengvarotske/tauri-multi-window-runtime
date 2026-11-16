//! Run with: cargo run -p shared-runtime --locked --example recipes -- shared|window|io
//!
//! CLI caller labels below are trusted illustrations. A Tauri application must
//! derive identity with shared_runtime_tauri::caller(&window) and use capabilities.

use shared_runtime::{
    CachePolicy, CallOptions, Caller, OpContext, Operation, OperationConfig, ResponseBudget,
    Runtime, RuntimeConfig, ScopeRule, View, ViewCallError, ViewError,
};
use std::{
    convert::Infallible,
    fs::{self, OpenOptions},
    io::{self, Write},
    path::PathBuf,
    process::ExitCode,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};

// Limits for these tiny recipes only; choose and measure your application's limits.
fn recipe_config(cache_budget_bytes: usize) -> RuntimeConfig {
    RuntimeConfig {
        max_concurrent_operations: 2,
        max_queued_operations: 2,
        max_concurrent_projections: 2,
        max_queued_projections: 2,
        default_deadline: Duration::from_secs(5),
        shutdown_grace: Duration::from_secs(1),
        cache_budget_bytes,
    }
}

struct Catalog;

impl Operation for Catalog {
    const NAME: &'static str = "recipes.catalog";
    type Params = ();
    type Output = Vec<String>;
    type Error = Infallible;

    fn policy(&self) -> CachePolicy {
        CachePolicy::Forever
    }

    fn weight(&self, output: &Vec<String>) -> usize {
        output.capacity() * std::mem::size_of::<String>()
            + output.iter().map(String::capacity).sum::<usize>()
    }

    async fn run(&self, _ctx: OpContext, _params: ()) -> Result<Vec<String>, Infallible> {
        Ok(["alpha", "bravo", "charlie", "delta"]
            .into_iter()
            .map(str::to_owned)
            .collect())
    }
}

struct PageRequest {
    offset: usize,
    limit: usize,
}

struct CatalogPage;

impl View<Catalog> for CatalogPage {
    const NAME: &'static str = "recipes.catalog.page";
    type Request = PageRequest;
    type Response = Vec<String>;

    fn source(&self, _request: &PageRequest) {}

    fn max_items(&self) -> usize {
        2
    }

    fn max_response_bytes(&self) -> usize {
        128
    }

    fn project(
        &self,
        output: &Vec<String>,
        request: PageRequest,
        budget: &mut ResponseBudget,
    ) -> Result<Vec<String>, ViewError> {
        if !(1..=self.max_items()).contains(&request.limit) || request.offset > output.len() {
            return Err(ViewError::InvalidRequest(
                "use a valid offset and a limit from 1 to 2".into(),
            ));
        }
        let end = request
            .offset
            .saturating_add(request.limit)
            .min(output.len());
        let mut page = Vec::with_capacity(end - request.offset);
        for item in &output[request.offset..end] {
            // Charge each item's storage before allocating its owned copy.
            budget.take(std::mem::size_of::<String>() + item.len())?;
            page.push(item.clone());
        }
        Ok(page)
    }

    fn items(response: &Vec<String>) -> usize {
        response.len()
    }

    fn response_bytes(response: &Vec<String>) -> usize {
        response
            .iter()
            .map(|item| std::mem::size_of::<String>() + item.len())
            .sum()
    }
}

async fn shared_recipe() {
    let runtime = Runtime::builder(recipe_config(4096))
        .expect("valid recipe limits")
        .register(
            Catalog,
            OperationConfig {
                cache_budget_bytes: 4096,
            },
        )
        .expect("catalog fits its reserved budget")
        .view(CatalogPage)
        .expect("catalog view is registered once")
        .build();
    let main = Caller::window("main");
    let inspector = Caller::window("inspector");
    let source = runtime.operation::<Catalog>().expect("registered catalog");
    let first = source.get(&main, (), CallOptions::default()).await.unwrap();
    let second = source
        .get(&inspector, (), CallOptions::default())
        .await
        .unwrap();
    assert!(Arc::ptr_eq(&first, &second));

    let view = runtime
        .view::<Catalog, CatalogPage>()
        .expect("registered page");
    let left = view
        .get(
            &main,
            PageRequest {
                offset: 0,
                limit: 2,
            },
            CallOptions::default(),
        )
        .await
        .unwrap();
    let right = view
        .get(
            &inspector,
            PageRequest {
                offset: 2,
                limit: 2,
            },
            CallOptions::default(),
        )
        .await
        .unwrap();
    assert_eq!(left, ["alpha", "bravo"]);
    assert_eq!(right, ["charlie", "delta"]);
    assert!(CatalogPage::response_bytes(&left) <= 128);
    assert!(CatalogPage::response_bytes(&right) <= 128);
    assert!(matches!(
        view.get(
            &main,
            PageRequest {
                offset: 0,
                limit: 3
            },
            CallOptions::default()
        )
        .await,
        Err(ViewCallError::View(ViewError::InvalidRequest(_)))
    ));
    let stats = source.stats();
    assert_eq!(stats.executed, 1);
    assert_eq!(stats.cache_entries, 1);
    assert!(stats.cache_weight_bytes <= 4096);
    println!(
        "Shared: two callers hold the same cached Rust source; one execution, one cache entry."
    );
    println!("Bounded pages (2 items, 128 bytes maximum): {left:?} and {right:?}.");
    println!("A request for 3 items was rejected. These checks do not measure whole-app RAM.");
    runtime.shutdown().await;
}

struct WindowState {
    generations: Arc<AtomicUsize>,
}

impl Operation for WindowState {
    const NAME: &'static str = "recipes.window-state";
    type Params = ();
    type Output = usize;
    type Error = Infallible;

    fn policy(&self) -> CachePolicy {
        CachePolicy::Forever
    }

    fn scope(&self) -> ScopeRule {
        ScopeRule::PerWindow
    }

    fn weight(&self, _output: &usize) -> usize {
        std::mem::size_of::<usize>()
    }

    async fn run(&self, _ctx: OpContext, _params: ()) -> Result<usize, Infallible> {
        Ok(self.generations.fetch_add(1, Ordering::SeqCst) + 1)
    }
}

async fn window_recipe() {
    let runtime = Runtime::builder(recipe_config(128))
        .expect("valid recipe limits")
        .register(
            WindowState {
                generations: Arc::new(AtomicUsize::new(0)),
            },
            OperationConfig {
                cache_budget_bytes: 128,
            },
        )
        .expect("window state fits its reserved budget")
        .build();
    let main = Caller::window("main");
    let inspector = Caller::window("inspector");
    let state = runtime
        .operation::<WindowState>()
        .expect("registered state");
    let old_main = state.get(&main, (), CallOptions::default()).await.unwrap();
    let other = state
        .get(&inspector, (), CallOptions::default())
        .await
        .unwrap();
    let repeated = state.get(&main, (), CallOptions::default()).await.unwrap();
    assert_ne!(*old_main, *other);
    assert!(Arc::ptr_eq(&old_main, &repeated));
    assert_eq!(state.stats().cache_entries, 2);

    // A Tauri adapter hooks actual window destruction; this CLI simulates it.
    assert_eq!(runtime.forget_window(&main), 1);
    assert_eq!(state.stats().cache_entries, 1);
    let reopened = Caller::window("main");
    let new_main = state
        .get(&reopened, (), CallOptions::default())
        .await
        .unwrap();
    let still_other = state
        .get(&inspector, (), CallOptions::default())
        .await
        .unwrap();
    assert_ne!(*old_main, *new_main);
    assert!(!Arc::ptr_eq(&old_main, &new_main));
    assert!(Arc::ptr_eq(&other, &still_other));
    assert_eq!(state.stats().executed, 3);
    assert_eq!(runtime.forget_window(&reopened), 1);
    assert_eq!(runtime.forget_window(&inspector), 1);
    assert_eq!(state.stats().cache_entries, 0);
    println!(
        "Window: main generation {old_main}, inspector generation {other}; each has its own cache."
    );
    println!("After forgetting main, reopening its label produced generation {new_main}.");
    println!("Inspector kept its value; forgetting both windows left zero cached entries.");
    println!("Existing Arc holders keep their values alive until those holders drop them.");
    runtime.shutdown().await;
}

const FIXTURE_CONTENT: &[u8] = b"small owned recipe fixture\n";

// Own exactly the file created with create_new, including cleanup on early return.
struct TempFixture {
    path: PathBuf,
    removed: bool,
}

impl TempFixture {
    fn create() -> io::Result<Self> {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(io::Error::other)?
            .as_nanos();
        let prefix = format!("shared-runtime-recipes-io-{}-{stamp}", std::process::id());
        for attempt in 0..16 {
            let path = std::env::temp_dir().join(format!("{prefix}-{attempt}.tmp"));
            match OpenOptions::new().write(true).create_new(true).open(&path) {
                Ok(mut file) => {
                    let fixture = Self {
                        path,
                        removed: false,
                    };
                    let written = file.write_all(FIXTURE_CONTENT);
                    // Close the handle before the guard could remove it on Windows.
                    drop(file);
                    written?;
                    return Ok(fixture);
                }
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
                Err(error) => return Err(error),
            }
        }
        Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "could not create a unique recipe fixture",
        ))
    }

    fn remove(mut self) -> io::Result<()> {
        fs::remove_file(&self.path)?;
        self.removed = true;
        Ok(())
    }
}

impl Drop for TempFixture {
    fn drop(&mut self) {
        if !self.removed {
            // No directory traversal, recursive removal, or user-supplied paths.
            let _ = fs::remove_file(&self.path);
        }
    }
}

struct ReadFixture {
    path: PathBuf,
    reads: Arc<AtomicUsize>,
}

impl Operation for ReadFixture {
    const NAME: &'static str = "recipes.file-read";
    type Params = ();
    type Output = Vec<u8>;
    type Error = io::Error;

    fn policy(&self) -> CachePolicy {
        CachePolicy::NoStore
    }

    fn weight(&self, output: &Vec<u8>) -> usize {
        output.capacity()
    }

    async fn run(&self, _ctx: OpContext, _params: ()) -> io::Result<Vec<u8>> {
        // With biased join below, both same-key calls register before this resumes.
        tokio::task::yield_now().await;
        let path = self.path.clone();
        let reads = Arc::clone(&self.reads);
        tokio::task::spawn_blocking(move || {
            reads.fetch_add(1, Ordering::SeqCst);
            fs::read(path)
        })
        .await
        .map_err(io::Error::other)?
    }
}

async fn io_recipe() {
    let fixture = tokio::task::spawn_blocking(TempFixture::create)
        .await
        .expect("fixture worker completed")
        .expect("create owned fixture");
    let reads = Arc::new(AtomicUsize::new(0));
    let runtime = Runtime::builder(recipe_config(0))
        .expect("valid recipe limits")
        .register(
            ReadFixture {
                path: fixture.path.clone(),
                reads: Arc::clone(&reads),
            },
            OperationConfig {
                cache_budget_bytes: 0,
            },
        )
        .expect("uncached operation needs no reserved cache bytes")
        .build();
    let main = Caller::window("main");
    let inspector = Caller::window("inspector");
    let read = runtime.operation::<ReadFixture>().expect("registered read");
    let (first, second) = tokio::join!(
        biased;
        read.get(&main, (), CallOptions::default()),
        read.get(&inspector, (), CallOptions::default()),
    );
    let first = first.expect("first file read");
    let second = second.expect("second file read");
    assert_eq!(first.as_slice(), FIXTURE_CONTENT);
    assert!(Arc::ptr_eq(&first, &second));
    assert_eq!(reads.load(Ordering::SeqCst), 1);
    let stats = read.stats();
    assert_eq!(
        (stats.executed, stats.coalesced, stats.cache_hits),
        (1, 1, 0)
    );
    assert_eq!(stats.cache_entries, 0);
    println!("IO: two concurrent callers shared one blocking file read and the same Rust output.");

    let later = read
        .get(&main, (), CallOptions::default())
        .await
        .expect("later file read");
    assert_eq!(later.as_slice(), FIXTURE_CONTENT);
    assert_eq!(reads.load(Ordering::SeqCst), 2);
    assert_eq!(read.stats().cache_entries, 0);
    runtime.shutdown().await;
    tokio::task::spawn_blocking(move || fixture.remove())
        .await
        .expect("cleanup worker completed")
        .expect("remove only the owned fixture");
    println!("NoStore: a later call read again. The owned temporary file was removed.");
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> ExitCode {
    let mut args = std::env::args().skip(1);
    let mode = args.next();
    if args.next().is_some() {
        eprintln!(
            "Usage: cargo run -p shared-runtime --locked --example recipes -- shared|window|io"
        );
        return ExitCode::FAILURE;
    }
    match mode.as_deref() {
        Some("shared") => shared_recipe().await,
        Some("window") => window_recipe().await,
        Some("io") => io_recipe().await,
        _ => {
            eprintln!(
                "Usage: cargo run -p shared-runtime --locked --example recipes -- shared|window|io"
            );
            return ExitCode::FAILURE;
        }
    }
    ExitCode::SUCCESS
}
