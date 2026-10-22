
use std::{
    collections::HashMap,
    future::Future,
    hash::Hash,
    sync::Arc,
};

use tokio::sync::{Mutex, OnceCell};

/// Координирует одинаковые параллельные операции.
///
/// Для одного ключа операция выполняется один раз,
/// а остальные вызывающие получают тот же результат.
///
/// Это пока не кэш: после завершения операции запись удаляется.
pub struct TaskCoalescer<K, V, E> {
    tasks: Mutex<HashMap<K, Arc<OnceCell<Result<Arc<V>, Arc<E>>>>>>,
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
        let cell = {
            let mut tasks = self.tasks.lock().await;

            tasks
                .entry(key.clone())
                .or_insert_with(|| Arc::new(OnceCell::new()))
                .clone()
        };

        // Mutex<HashMap> уже освобождён.
        // Ожидание операции не блокирует другие ключи.
        let result = cell
            .get_or_init(|| async move {
                operation()
                    .await
                    .map(Arc::new)
                    .map_err(Arc::new)
            })
            .await
            .clone();

        // Удаляем только завершённую запись, которой больше
        // не пользуются другие ожидающие вызовы.
        if Arc::strong_count(&cell) == 2 {
            let mut tasks = self.tasks.lock().await;

            if let Some(current) = tasks.get(&key) {
                if Arc::ptr_eq(current, &cell) && Arc::strong_count(current) == 2 {
                    tasks.remove(&key);
                }
            }
        }

        result
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

            assert_eq!(
                result.unwrap_err().as_str(),
                "temporary failure"
            );
        }

        assert_eq!(executions.load(Ordering::SeqCst), 2);
    }
}
