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

            let entry = tasks
                .entry(key.clone())
                .or_insert_with(|| {
                    Arc::new(TaskEntry {
                        cell: OnceCell::new(),
                        callers: AtomicUsize::new(0),
                    })
                })
                .clone();

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

        let kind = if initialized_by_this_call.load(Ordering::Relaxed) {
            CoalescerRunKind::Executed
        } else {
            CoalescerRunKind::Coalesced
        };

        (result, kind)
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
