use serde::Serialize;
use shared_runtime::{CallOptions, Caller, Operation, RegistryError, Runtime, View};
use std::{sync::Arc, time::Duration};
use tauri::WebviewWindow;

use crate::{AdapterError, JsonBytes, codec::encode_json};

/// The caller of a command: the window Tauri injected into it.
///
/// This is the only place the adapter builds a [`Caller`]. A command must
/// never build one from a value in its request: a label the frontend sends
/// proves nothing. The label separates `PerWindow` data; it is not an access
/// check. Which window may run which command is decided by Tauri
/// capabilities, before the command runs.
pub fn caller<R: tauri::Runtime>(window: &WebviewWindow<R>) -> Caller {
    Caller::window(window.label())
}

/// The application's one runtime, stored as Tauri state by [`init`](crate::init).
///
/// Commands take it as `State<'_, SharedRuntime>`.
pub struct SharedRuntime {
    runtime: Arc<Runtime>,
    abort_wait: Duration,
}

impl SharedRuntime {
    pub(crate) fn new(runtime: Runtime, abort_wait: Duration) -> Self {
        Self {
            runtime: Arc::new(runtime),
            abort_wait,
        }
    }

    /// The runtime itself, for stats and for calls whose result stays in Rust.
    pub fn runtime(&self) -> &Runtime {
        &self.runtime
    }

    /// Runs view `V` of operation `O` for `caller` and returns its response
    /// serialized as JSON.
    ///
    /// Serialization happens inside `ViewHandle::get_with`, while the
    /// projection slot is held, so the serialized copy counts against
    /// `RuntimeConfig::max_concurrent_projections` like the response itself.
    /// It stops as soon as the output would pass `max_response_bytes`; the
    /// view's own `max_items` and `max_response_bytes` are checked before.
    pub async fn view<O, V>(
        &self,
        caller: &Caller,
        request: V::Request,
        max_response_bytes: usize,
        options: CallOptions,
    ) -> Result<JsonBytes, AdapterError>
    where
        O: Operation,
        V: View<O>,
        V::Response: Serialize,
    {
        let handle = self.runtime.view::<O, V>().map_err(internal)?;
        handle
            .get_with(caller, request, options, |response| {
                encode_json(&response, max_response_bytes)
            })
            .await
            .map_err(AdapterError::from_view_call)?
    }

    /// Runs operation `O` for `caller` and returns `respond(&output)`
    /// serialized as JSON, at most `max_response_bytes`.
    ///
    /// For small results (a status, a count, a summary). The output stays in
    /// Rust; `respond` picks what leaves it. Unlike [`view`](Self::view) this
    /// is not under the projection limit, so anything that grows with the
    /// data belongs in a view.
    pub async fn call<O, T>(
        &self,
        caller: &Caller,
        params: O::Params,
        max_response_bytes: usize,
        options: CallOptions,
        respond: impl FnOnce(&O::Output) -> T,
    ) -> Result<JsonBytes, AdapterError>
    where
        O: Operation,
        T: Serialize,
    {
        let handle = self.runtime.operation::<O>().map_err(internal)?;
        let output = handle
            .get(caller, params, options)
            .await
            .map_err(AdapterError::from_call)?;
        encode_json(&respond(&output), max_response_bytes)
    }

    /// Drops the `PerWindow` outputs of a destroyed window. Called by the
    /// plugin on `WindowEvent::Destroyed`.
    pub fn forget_window(&self, label: &str) -> usize {
        self.runtime.forget_window(&Caller::window(label))
    }

    /// Shuts the runtime down and waits: calls in flight get the runtime's
    /// `shutdown_grace`, then `abort_wait` more to observe the abort. Returns
    /// `false` if they had not all ended by then. Called by the plugin when
    /// the application exits; later calls return `SHUTTING_DOWN`.
    pub async fn shutdown(&self) -> bool {
        let limit = self
            .runtime
            .config()
            .shutdown_grace
            .saturating_add(self.abort_wait);
        tokio::time::timeout(limit, self.runtime.shutdown())
            .await
            .is_ok()
    }
}

/// A registry error names Rust types; the WebView gets only the class.
fn internal(_error: RegistryError) -> AdapterError {
    AdapterError::internal()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::AdapterErrorCode;
    use serde::Serializer;
    use shared_runtime::{
        CachePolicy, OpContext, OperationConfig, ResponseBudget, RuntimeConfig, ScopeRule,
        ViewError,
    };
    use std::{
        convert::Infallible,
        sync::{Mutex, mpsc},
    };

    fn config(projections: usize, grace: Duration) -> RuntimeConfig {
        RuntimeConfig {
            max_concurrent_operations: 4,
            max_queued_operations: 16,
            max_concurrent_projections: projections,
            default_deadline: Duration::from_secs(5),
            shutdown_grace: grace,
            cache_budget_bytes: 1 << 20,
        }
    }

    #[tokio::test]
    async fn configuration_with_large_shutdown_budget_does_not_overflow() {
        let runtime = Runtime::builder(config(1, Duration::MAX)).unwrap().build();
        let state = SharedRuntime::new(runtime, Duration::from_secs(1));
        assert!(state.shutdown().await);
    }

    /// Lets a test hold a response in the middle of its serialization.
    #[derive(Default)]
    struct Gate {
        entered: Mutex<Option<mpsc::Sender<()>>>,
        release: Mutex<Option<mpsc::Receiver<()>>>,
    }

    struct Strings(ScopeRule);

    impl Operation for Strings {
        const NAME: &'static str = "test.strings";
        type Params = u32;
        type Output = Vec<String>;
        type Error = Infallible;

        fn policy(&self) -> CachePolicy {
            CachePolicy::Forever
        }

        fn scope(&self) -> ScopeRule {
            self.0
        }

        fn weight(&self, output: &Vec<String>) -> usize {
            output.iter().map(String::len).sum()
        }

        async fn run(&self, _ctx: OpContext, len: u32) -> Result<Vec<String>, Infallible> {
            Ok(vec!["x".repeat(len as usize); 4])
        }
    }

    struct Response {
        strings: Vec<String>,
        gate: Option<Arc<Gate>>,
    }

    impl Serialize for Response {
        fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
            if let Some(gate) = &self.gate
                && let Some(entered) = gate.entered.lock().unwrap().take()
            {
                entered.send(()).unwrap();
                let release = gate.release.lock().unwrap().take().unwrap();
                release.recv().unwrap();
            }
            self.strings.serialize(serializer)
        }
    }

    struct All {
        gate: Arc<Gate>,
    }

    impl View<Strings> for All {
        const NAME: &'static str = "test.strings.all";
        type Request = u32;
        type Response = Response;

        fn source(&self, len: &u32) -> u32 {
            *len
        }

        fn max_items(&self) -> usize {
            4
        }

        fn max_response_bytes(&self) -> usize {
            1 << 20
        }

        fn project(
            &self,
            output: &Vec<String>,
            _len: u32,
            budget: &mut ResponseBudget,
        ) -> Result<Response, ViewError> {
            for string in output {
                budget.take(string.len())?;
            }
            Ok(Response {
                strings: output.clone(),
                gate: Some(Arc::clone(&self.gate)),
            })
        }

        fn items(response: &Response) -> usize {
            response.strings.len()
        }

        fn response_bytes(response: &Response) -> usize {
            response.strings.iter().map(String::len).sum()
        }
    }

    fn shared(projections: usize, gate: Arc<Gate>) -> SharedRuntime {
        scoped(projections, gate, ScopeRule::Shared)
    }

    fn scoped(projections: usize, gate: Arc<Gate>, scope: ScopeRule) -> SharedRuntime {
        let runtime = Runtime::builder(config(projections, Duration::from_millis(50)))
            .unwrap()
            .register(
                Strings(scope),
                OperationConfig {
                    cache_budget_bytes: 1 << 20,
                },
            )
            .unwrap()
            .view::<Strings, _>(All { gate })
            .unwrap()
            .build();
        SharedRuntime::new(runtime, Duration::from_secs(1))
    }

    #[tokio::test]
    async fn serialized_response_over_the_limit_is_refused() {
        let state = shared(1, Arc::default());
        let caller = Caller::window("main");
        // 4 strings of 100 bytes serialize to 4 × 102 + 3 + 2 = 413 bytes.
        let ok = state
            .view::<Strings, All>(&caller, 100, 413, CallOptions::default())
            .await
            .unwrap();
        assert_eq!(ok.len(), 413);
        let error = state
            .view::<Strings, All>(&caller, 100, 412, CallOptions::default())
            .await
            .unwrap_err();
        assert_eq!(error.code(), AdapterErrorCode::ResponseTooLarge);
    }

    /// Serialization runs while the projection slot is held: with one slot, a
    /// second call waits behind a serialization in progress and reaches its
    /// deadline.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn serialization_is_inside_the_projection_limit() {
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let gate = Arc::new(Gate {
            entered: Mutex::new(Some(entered_tx)),
            release: Mutex::new(Some(release_rx)),
        });
        let state = Arc::new(shared(1, gate));
        let first = tokio::spawn({
            let state = Arc::clone(&state);
            async move {
                state
                    .view::<Strings, All>(
                        &Caller::window("main"),
                        10,
                        1 << 20,
                        CallOptions::default(),
                    )
                    .await
            }
        });
        tokio::task::spawn_blocking(move || entered_rx.recv().unwrap())
            .await
            .unwrap();

        let second = state
            .view::<Strings, All>(
                &Caller::window("w1"),
                10,
                1 << 20,
                CallOptions {
                    deadline: Some(Duration::from_millis(100)),
                },
            )
            .await
            .unwrap_err();
        assert_eq!(second.code(), AdapterErrorCode::DeadlineExceeded);
        assert!(
            second.message().contains("projection slot"),
            "{}",
            second.message()
        );
        let stats = state.runtime().stats();
        release_tx.send(()).unwrap();
        assert!(first.await.unwrap().is_ok());
        assert_eq!(
            stats.operation(Strings::NAME).unwrap().requests,
            1,
            "a queued view must not fetch or retain its source"
        );

        // The slot is free again.
        assert!(
            state
                .view::<Strings, All>(&Caller::window("w1"), 10, 1 << 20, CallOptions::default())
                .await
                .is_ok()
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn closing_a_window_while_its_view_is_queued_does_not_recache_through_the_adapter() {
        use std::{
            future::Future,
            task::{Context, Waker},
        };
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let state = Arc::new(scoped(
            1,
            Arc::new(Gate {
                entered: Mutex::new(Some(entered_tx)),
                release: Mutex::new(Some(release_rx)),
            }),
            ScopeRule::PerWindow,
        ));
        let first = tokio::spawn({
            let state = Arc::clone(&state);
            async move {
                state
                    .view::<Strings, All>(
                        &Caller::window("main"),
                        10,
                        1 << 20,
                        CallOptions::default(),
                    )
                    .await
            }
        });
        tokio::task::spawn_blocking(move || entered_rx.recv().unwrap())
            .await
            .unwrap();
        let closing = Caller::window("closing");
        let mut queued =
            Box::pin(state.view::<Strings, All>(&closing, 20, 1 << 20, CallOptions::default()));
        assert!(
            queued
                .as_mut()
                .poll(&mut Context::from_waker(Waker::noop()))
                .is_pending()
        );
        assert_eq!(
            state
                .runtime()
                .stats()
                .operation(Strings::NAME)
                .unwrap()
                .requests,
            1
        );
        assert_eq!(state.forget_window("closing"), 0);
        release_tx.send(()).unwrap();
        assert!(first.await.unwrap().is_ok());
        let response = tokio::time::timeout(Duration::from_secs(5), queued)
            .await
            .unwrap()
            .unwrap();
        let strings: Vec<String> = serde_json::from_slice(response.as_bytes()).unwrap();
        assert_eq!(strings, vec!["x".repeat(20); 4]);
        assert_eq!(
            state
                .runtime()
                .stats()
                .operation(Strings::NAME)
                .unwrap()
                .cache_entries,
            1,
            "the adapter's queued call repopulated the closed window's cache"
        );
    }

    struct Slow;

    impl Operation for Slow {
        const NAME: &'static str = "test.slow";
        type Params = ();
        type Output = ();
        type Error = Infallible;

        fn policy(&self) -> CachePolicy {
            CachePolicy::NoStore
        }

        fn scope(&self) -> ScopeRule {
            ScopeRule::PerWindow
        }

        fn weight(&self, _output: &()) -> usize {
            0
        }

        async fn run(&self, _ctx: OpContext, _params: ()) -> Result<(), Infallible> {
            tokio::time::sleep(Duration::from_secs(60)).await;
            Ok(())
        }
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn shutdown_ends_calls_in_flight_within_grace_and_refuses_new_ones() {
        let runtime = Runtime::builder(config(1, Duration::from_millis(50)))
            .unwrap()
            .register(
                Slow,
                OperationConfig {
                    cache_budget_bytes: 0,
                },
            )
            .unwrap()
            .build();
        let state = Arc::new(SharedRuntime::new(runtime, Duration::from_secs(1)));
        let call = tokio::spawn({
            let state = Arc::clone(&state);
            async move {
                state
                    .call::<Slow, _>(
                        &Caller::window("main"),
                        (),
                        64,
                        CallOptions::default(),
                        |_| (),
                    )
                    .await
            }
        });
        while state.runtime().stats().operations[0].in_flight == 0 {
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
        let started = std::time::Instant::now();
        assert!(
            state.shutdown().await,
            "every call ended within grace + abort_wait"
        );
        assert!(started.elapsed() < Duration::from_secs(1));
        assert_eq!(
            call.await.unwrap().unwrap_err().code(),
            AdapterErrorCode::ShuttingDown
        );
        let later = state
            .call::<Slow, _>(
                &Caller::window("main"),
                (),
                64,
                CallOptions::default(),
                |_| (),
            )
            .await
            .unwrap_err();
        assert_eq!(later.code(), AdapterErrorCode::ShuttingDown);
    }

    #[tokio::test]
    async fn unregistered_operations_and_views_are_internal_errors() {
        let runtime = Runtime::builder(config(1, Duration::from_millis(50)))
            .unwrap()
            .build();
        let state = SharedRuntime::new(runtime, Duration::from_secs(1));
        let caller = Caller::window("main");
        let error = state
            .call::<Strings, _>(&caller, 1, 64, CallOptions::default(), |_| ())
            .await
            .unwrap_err();
        assert_eq!(error.code(), AdapterErrorCode::Internal);
        assert_eq!(error.message(), crate::error::messages::INTERNAL);
        let error = state
            .view::<Strings, All>(&caller, 1, 64, CallOptions::default())
            .await
            .unwrap_err();
        assert_eq!(error.code(), AdapterErrorCode::Internal);
        assert_eq!(error.message(), crate::error::messages::INTERNAL);
        let envelope = serde_json::to_string(&error).unwrap();
        assert!(!envelope.contains("Strings"), "{envelope}");
    }
}
