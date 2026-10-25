pub mod cache;
pub mod cache_policy;
pub mod service;

pub use cache::PolicyCache;
pub use cache_policy::CachePolicy;
pub use service::{CachedService, ServiceRunKind, ServiceRunOutcome};
use std::{
    collections::HashMap,
    future::Future,
    hash::Hash,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
};

use tokio::sync::OnceCell;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CoalescerRunKind {
    Executed,
    Coalesced,
}

/// Одна операция и количество вызовов, которые используют её.
struct TaskEntry<V, E> {
    cell: OnceCell<Result<Arc<V>, Arc<E>>>,
    callers: AtomicUsize,
}

impl<V, E> TaskEntry<V, E> {
    fn new_arc() -> Arc<Self> {
        Arc::new(Self {
            cell: OnceCell::new(),
            callers: AtomicUsize::new(0),
        })
    }
}

/// Удаляет запись при завершении или отмене вызывающего вызова.
struct CallerGuard<'a, K: Eq + Hash, V, E> {
    tasks: &'a Mutex<HashMap<K, Arc<TaskEntry<V, E>>>>,
    key: K,
    entry: Arc<TaskEntry<V, E>>,
}

impl<K, V, E> Drop for CallerGuard<'_, K, V, E>
where
    K: Eq + Hash,
{
    fn drop(&mut self) {
        let mut tasks = self.tasks.lock().unwrap_or_else(|p| p.into_inner());

        let previous = self.entry.callers.fetch_sub(1, Ordering::Relaxed);

        if previous == 1
            && tasks
                .get(&self.key)
                .is_some_and(|current| Arc::ptr_eq(current, &self.entry))
        {
            tasks.remove(&self.key);
        }
    }
}

/// Объединяет одинаковые параллельные операции.
/// Результаты не кэшируются после завершения всех вызовов.
pub struct TaskCoalescer<K, V, E> {
    tasks: Mutex<HashMap<K, Arc<TaskEntry<V, E>>>>,
}

impl<K, V, E> Default for TaskCoalescer<K, V, E>
where
    K: Eq + Hash,
{
    fn default() -> Self {
        Self {
            tasks: Mutex::new(HashMap::new()),
        }
    }
}

impl<K, V, E> TaskCoalescer<K, V, E>
where
    K: Eq + Hash + Clone,
{
    pub fn new() -> Self {
        Self::default()
    }

    pub async fn run<F, Fut>(&self, key: K, operation: F) -> Result<Arc<V>, Arc<E>>
    where
        F: FnOnce() -> Fut,
        Fut: Future<Output = Result<V, E>>,
    {
        self.run_with_kind(key, operation).await.0
    }

    pub(crate) async fn run_with_kind<F, Fut>(
        &self,
        key: K,
        operation: F,
    ) -> (Result<Arc<V>, Arc<E>>, CoalescerRunKind)
    where
        F: FnOnce() -> Fut,
        Fut: Future<Output = Result<V, E>>,
    {
        let entry = {
            let mut tasks = self.tasks.lock().unwrap_or_else(|p| p.into_inner());
            #[cfg(test)]
            coalescer_probe::mark_join();

            let slot = tasks.entry(key.clone()).or_insert_with(TaskEntry::new_arc);
            // Результат уже опубликован: операция завершена, новый вызов
            // не присоединяется к ней, а начинает свою.
            if slot.cell.initialized() {
                *slot = TaskEntry::new_arc();
            }
            let entry = Arc::clone(slot);

            entry.callers.fetch_add(1, Ordering::Relaxed);
            entry
        };

        let _guard = CallerGuard {
            tasks: &self.tasks,
            key,
            entry: Arc::clone(&entry),
        };

        let initialized_by_this_call = Arc::new(AtomicBool::new(false));
        let initializer_flag = Arc::clone(&initialized_by_this_call);

        let result = entry
            .cell
            .get_or_init(|| async move {
                initializer_flag.store(true, Ordering::Relaxed);
                operation().await.map(Arc::new).map_err(Arc::new)
            })
            .await
            .clone();

        // Test-only: the initializer ticks after its result has been published.
        #[cfg(test)]
        if initialized_by_this_call.load(Ordering::Relaxed) {
            coalescer_probe::mark_done();
        }

        let kind = if initialized_by_this_call.load(Ordering::Relaxed) {
            CoalescerRunKind::Executed
        } else {
            CoalescerRunKind::Coalesced
        };

        (result, kind)
    }
}

/// Test-only ticks on the `service::probe` clock: `JOIN` is taken under the
/// `tasks` mutex when a call registers, `DONE` by the initializer after the
/// result is published. A call whose `JOIN` is greater than an operation's
/// `DONE` registered after that operation had completed.
#[cfg(test)]
pub(crate) mod coalescer_probe {
    use std::cell::Cell;
    tokio::task_local! {
        pub(crate) static JOIN: Cell<u64>;
        pub(crate) static DONE: Cell<u64>;
    }
    pub(crate) fn mark_join() {
        let tick = crate::service::probe::now();
        let _ = JOIN.try_with(|c| c.set(tick));
    }
    pub(crate) fn mark_done() {
        let tick = crate::service::probe::now();
        let _ = DONE.try_with(|c| c.set(tick));
    }
}

/// Test-only views of the in-flight table.
#[cfg(test)]
impl<K, V, E> TaskCoalescer<K, V, E> {
    pub(crate) fn test_len(&self) -> usize {
        self.tasks.lock().unwrap().len()
    }
    pub(crate) fn test_callers(&self) -> usize {
        self.tasks
            .lock()
            .unwrap()
            .values()
            .map(|e| e.callers.load(Ordering::SeqCst))
            .sum()
    }
}

#[cfg(test)]
mod tests {
    use super::TaskCoalescer;
    use std::{
        sync::{
            Arc,
            atomic::{AtomicUsize, Ordering},
        },
        time::Duration,
    };
    use tokio::task::JoinSet;

    #[tokio::test]
    async fn coalesces_concurrent_requests() {
        let coalescer = Arc::new(TaskCoalescer::<String, usize, String>::new());
        let executions = Arc::new(AtomicUsize::new(0));
        let mut tasks = JoinSet::new();

        for _ in 0..20 {
            let coalescer = Arc::clone(&coalescer);
            let executions = Arc::clone(&executions);

            tasks.spawn(async move {
                coalescer
                    .run("same-key".to_owned(), || async {
                        executions.fetch_add(1, Ordering::SeqCst);
                        tokio::time::sleep(Duration::from_millis(100)).await;
                        Ok(42)
                    })
                    .await
            });
        }

        for _ in 0..20 {
            let result = tasks.join_next().await.unwrap().unwrap().unwrap();
            assert_eq!(*result, 42);
        }

        assert_eq!(executions.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn different_keys_run_independently() {
        let coalescer = TaskCoalescer::<String, usize, String>::new();

        let first = coalescer
            .run("first".to_owned(), || async { Ok(10) })
            .await
            .unwrap();

        let second = coalescer
            .run("second".to_owned(), || async { Ok(20) })
            .await
            .unwrap();

        assert_eq!(*first, 10);
        assert_eq!(*second, 20);
    }

    #[tokio::test]
    async fn errors_are_shared_without_being_cached() {
        let coalescer = TaskCoalescer::<String, usize, String>::new();
        let executions = AtomicUsize::new(0);

        for _ in 0..2 {
            let result = coalescer
                .run("error".to_owned(), || async {
                    executions.fetch_add(1, Ordering::SeqCst);
                    Err::<usize, String>("temporary failure".to_owned())
                })
                .await;

            assert_eq!(result.unwrap_err().as_str(), "temporary failure");
        }

        assert_eq!(executions.load(Ordering::SeqCst), 2);
    }

    #[tokio::test]
    async fn retries_operation_after_initializer_is_cancelled() {
        let coalescer = Arc::new(TaskCoalescer::<String, usize, String>::new());
        let started = Arc::new(tokio::sync::Notify::new());

        let first_coalescer = Arc::clone(&coalescer);
        let first_started = Arc::clone(&started);

        let first_task = tokio::spawn(async move {
            first_coalescer
                .run("cancel-test".to_owned(), || async move {
                    first_started.notify_one();
                    tokio::time::sleep(Duration::from_secs(30)).await;
                    Ok(1)
                })
                .await
        });

        // Ждём, пока первая операция действительно начнётся.
        started.notified().await;

        // Отменяем задачу, выполнявшую первую операцию.
        first_task.abort();
        let _ = first_task.await;

        // Следующий вызов должен суметь выполнить операцию.
        let result = coalescer
            .run("cancel-test".to_owned(), || async { Ok(42) })
            .await
            .unwrap();

        assert_eq!(*result, 42);
    }

    #[tokio::test]
    async fn completed_tasks_can_be_run_again() {
        let coalescer = TaskCoalescer::<String, usize, String>::new();

        let first = coalescer
            .run("repeat".to_owned(), || async { Ok(10) })
            .await
            .unwrap();

        let second = coalescer
            .run("repeat".to_owned(), || async { Ok(20) })
            .await
            .unwrap();

        assert_eq!(*first, 10);
        assert_eq!(*second, 20);
    }

    #[tokio::test]
    async fn cancelled_last_caller_does_not_leave_stale_entry() {
        let coalescer = Arc::new(TaskCoalescer::<String, usize, String>::new());
        let started = Arc::new(tokio::sync::Notify::new());

        let task_coalescer = Arc::clone(&coalescer);
        let task_started = Arc::clone(&started);

        let task = tokio::spawn(async move {
            task_coalescer
                .run("abandoned-key".to_owned(), || async move {
                    task_started.notify_one();
                    tokio::time::sleep(Duration::from_secs(30)).await;
                    Ok(1)
                })
                .await
        });

        started.notified().await;

        task.abort();
        let _ = task.await;

        let tasks = coalescer.tasks.lock().unwrap();
        assert!(
            !tasks.contains_key("abandoned-key"),
            "cancelled operation left a stale entry"
        );
    }
    #[tokio::test]
    async fn remaining_caller_retries_after_initializer_is_cancelled() {
        let coalescer = Arc::new(TaskCoalescer::<String, usize, String>::new());

        let started = Arc::new(tokio::sync::Notify::new());
        let executions = Arc::new(AtomicUsize::new(0));

        // Первый вызов запускает долгую операцию.
        let first_coalescer = Arc::clone(&coalescer);
        let first_started = Arc::clone(&started);
        let first_executions = Arc::clone(&executions);

        let first_task = tokio::spawn(async move {
            first_coalescer
                .run("shared-key".to_owned(), || async move {
                    first_executions.fetch_add(1, Ordering::SeqCst);
                    first_started.notify_one();

                    tokio::time::sleep(Duration::from_secs(30)).await;
                    Ok(1)
                })
                .await
        });

        // Ждём начала первой операции.
        started.notified().await;

        // Второй вызов использует тот же ключ.
        let second_coalescer = Arc::clone(&coalescer);
        let second_executions = Arc::clone(&executions);

        let second_task = tokio::spawn(async move {
            second_coalescer
                .run("shared-key".to_owned(), || async move {
                    second_executions.fetch_add(1, Ordering::SeqCst);
                    Ok(42)
                })
                .await
        });

        // Убеждаемся, что оба вызова зарегистрированы.
        tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                let caller_count = {
                    let tasks = coalescer.tasks.lock().unwrap();

                    tasks
                        .get("shared-key")
                        .map(|entry| entry.callers.load(Ordering::SeqCst))
                        .unwrap_or(0)
                };

                if caller_count == 2 {
                    break;
                }

                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("second caller did not join the shared operation");

        // Отменяем первый вызов.
        first_task.abort();
        let _ = first_task.await;

        // Второй вызов должен завершиться успешно.
        let result = tokio::time::timeout(Duration::from_secs(2), second_task)
            .await
            .expect("remaining caller did not finish")
            .expect("remaining caller task panicked")
            .expect("remaining caller returned an error");

        assert_eq!(*result, 42);
        assert_eq!(executions.load(Ordering::SeqCst), 2);

        // После завершения не должно остаться старой записи.
        let tasks = coalescer.tasks.lock().unwrap();

        assert!(
            !tasks.contains_key("shared-key"),
            "completed operation left a stale entry"
        );
    }
}

#[cfg(test)]
mod completed_operation {
    use super::{CoalescerRunKind, TaskCoalescer};
    use std::{
        future::Future,
        pin::Pin,
        sync::{
            Arc,
            atomic::{AtomicUsize, Ordering},
        },
        task::{Context, Poll, Waker},
        time::Duration,
    };
    use tokio::{
        sync::{Notify, Semaphore},
        time::timeout,
    };

    const LIMIT: Duration = Duration::from_secs(5);
    fn poll_once<F: Future>(f: Pin<&mut F>) -> Poll<F::Output> {
        f.poll(&mut Context::from_waker(Waker::noop()))
    }
    async fn wait_until(mut cond: impl FnMut() -> bool, what: &str) {
        timeout(LIMIT, async {
            while !cond() {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap_or_else(|_| panic!("timed out waiting for: {what}"));
    }

    async fn b1_case(fail: bool) {
        let c = TaskCoalescer::<u8, u64, String>::new();
        let gate = Arc::new(Notify::new());
        let g = gate.clone();
        let mut a = Box::pin(c.run_with_kind(1, move || async move {
            g.notified().await;
            if fail { Err("boom".to_owned()) } else { Ok(1) }
        }));
        assert!(poll_once(a.as_mut()).is_pending());
        let mut w = Box::pin(c.run_with_kind(1, || async { Ok(2) }));
        assert!(poll_once(w.as_mut()).is_pending());
        gate.notify_one();
        let (ra, ka) = a.await;
        assert_eq!((ra.is_err(), ka), (fail, CoalescerRunKind::Executed));
        let (rn, kn) = c.run_with_kind(1, || async { Ok(3) }).await;
        assert_eq!(
            kn,
            CoalescerRunKind::Executed,
            "new caller joined a finished entry (fail={fail})"
        );
        assert_eq!(*rn.unwrap(), 3);
        let (rw, kw) = w.await;
        assert_eq!(kw, CoalescerRunKind::Coalesced);
        assert_eq!(rw.is_err(), fail);
        assert_eq!(c.test_len(), 0);
    }
    #[tokio::test]
    async fn b1_new_caller_after_completion_starts_new_operation() {
        b1_case(false).await;
        b1_case(true).await;
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn b2_stale_caller_guard_does_not_remove_newer_entry() {
        let c = Arc::new(TaskCoalescer::<u8, u64, String>::new());
        let gate = Arc::new(Notify::new());
        let g = gate.clone();
        let mut a = Box::pin(c.run_with_kind(1, move || async move {
            g.notified().await;
            Ok(1)
        }));
        assert!(poll_once(a.as_mut()).is_pending());
        let mut w = Box::pin(c.run_with_kind(1, || async { Ok(2) }));
        assert!(poll_once(w.as_mut()).is_pending());
        gate.notify_one();
        let _ = a.await;
        // N registers a new entry for the same key and blocks behind its own gate
        let (n_gate, n_started) = (Arc::new(Semaphore::new(0)), Arc::new(AtomicUsize::new(0)));
        let n = {
            let (c, n_gate, n_started) = (c.clone(), n_gate.clone(), n_started.clone());
            tokio::spawn(async move {
                c.run_with_kind(1, move || async move {
                    n_started.fetch_add(1, Ordering::SeqCst);
                    let _open = n_gate.acquire().await.unwrap();
                    Ok(3)
                })
                .await
            })
        };
        wait_until(
            || n.is_finished() || n_started.load(Ordering::SeqCst) == 1,
            "N finished or started",
        )
        .await;
        assert_eq!(
            n_started.load(Ordering::SeqCst),
            1,
            "N reused the finished entry instead of starting its own"
        );
        drop(w); // the old waiter's guard is released after the newer entry exists
        assert_eq!(c.test_len(), 1, "stale guard removed the newer entry");
        let m = {
            let c = c.clone();
            tokio::spawn(async move { c.run_with_kind(1, || async { Ok(4) }).await })
        };
        wait_until(
            || m.is_finished() || c.test_callers() == 2,
            "M finished or joined",
        )
        .await;
        n_gate.add_permits(1);
        let (rn, kn) = timeout(LIMIT, n).await.unwrap().unwrap();
        let (rm, km) = timeout(LIMIT, m).await.unwrap().unwrap();
        assert_eq!((kn, *rn.unwrap()), (CoalescerRunKind::Executed, 3));
        assert_eq!(
            (km, *rm.unwrap()),
            (CoalescerRunKind::Coalesced, 3),
            "M did not join N's entry"
        );
        assert_eq!(c.test_len(), 0);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn b3_initializer_cancel_reexecutes_once_for_waiters() {
        let c = Arc::new(TaskCoalescer::<u8, u64, String>::new());
        let started = Arc::new(Notify::new());
        let a = {
            let (c, started) = (c.clone(), started.clone());
            tokio::spawn(async move {
                c.run_with_kind(1, move || async move {
                    started.notify_one();
                    std::future::pending::<()>().await;
                    Ok(1)
                })
                .await
            })
        };
        timeout(LIMIT, started.notified()).await.unwrap();
        let (gate, reexec) = (Arc::new(Semaphore::new(0)), Arc::new(AtomicUsize::new(0)));
        let spawn_waiter = |v: u64| {
            let (c, gate, reexec) = (c.clone(), gate.clone(), reexec.clone());
            tokio::spawn(async move {
                c.run_with_kind(1, move || async move {
                    reexec.fetch_add(1, Ordering::SeqCst);
                    let _open = gate.acquire().await.unwrap();
                    Ok(v)
                })
                .await
            })
        };
        let w1 = spawn_waiter(2);
        let w2 = spawn_waiter(3);
        wait_until(
            || c.test_callers() == 3 || reexec.load(Ordering::SeqCst) > 0,
            "two waiters joined or one executed",
        )
        .await;
        assert_eq!(
            reexec.load(Ordering::SeqCst),
            0,
            "a waiter executed while the initializer was still in flight"
        );
        a.abort();
        assert!(a.await.unwrap_err().is_cancelled());
        wait_until(
            || reexec.load(Ordering::SeqCst) >= 1,
            "one waiter re-executes",
        )
        .await;
        // a new caller during the re-execution joins it
        let n = spawn_waiter(4);
        wait_until(
            || n.is_finished() || c.test_callers() == 3 || reexec.load(Ordering::SeqCst) >= 2,
            "N finished, joined or executed separately",
        )
        .await;
        gate.add_permits(1);
        let r1 = timeout(LIMIT, w1).await.unwrap().unwrap();
        let r2 = timeout(LIMIT, w2).await.unwrap().unwrap();
        let rn = timeout(LIMIT, n).await.unwrap().unwrap();
        assert_eq!(
            reexec.load(Ordering::SeqCst),
            1,
            "unnecessary extra execution after initializer cancel"
        );
        let kinds = [r1.1, r2.1, rn.1];
        assert_eq!(
            kinds
                .iter()
                .filter(|k| **k == CoalescerRunKind::Executed)
                .count(),
            1
        );
        let v1 = *r1.0.unwrap();
        assert_eq!(
            (*r2.0.unwrap(), *rn.0.unwrap()),
            (v1, v1),
            "callers received different results"
        );
        assert_eq!(c.test_len(), 0);
    }
}
