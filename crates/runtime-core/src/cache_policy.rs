use std::time::{Duration, Instant};

/// Определяет, как долго результат может храниться в кэше.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CachePolicy {
    /// Не сохранять результат после завершения операции.
    NoStore,

    /// Хранить результат в течение указанного времени.
    Ttl(Duration),

    /// Хранить результат до явной инвалидации.
    Forever,
}

impl CachePolicy {
    /// Можно ли сохранять результат при такой политике.
    pub const fn should_store(self) -> bool {
        !matches!(self, Self::NoStore)
    }

    /// Нужно ли считать запись устаревшей.
    ///
    /// `inserted_at` — момент сохранения результата в кэш.
    /// `now` — момент проверки.
    ///
    /// При TTL запись истекает точно на границе времени:
    /// elapsed >= ttl.
    pub fn is_expired(self, inserted_at: Instant, now: Instant) -> bool {
        match self {
            Self::NoStore => true,
            Self::Ttl(ttl) => now.saturating_duration_since(inserted_at) >= ttl,
            Self::Forever => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::CachePolicy;
    use std::time::{Duration, Instant};

    #[test]
    fn no_store_disables_caching() {
        let policy = CachePolicy::NoStore;
        let now = Instant::now();

        assert!(!policy.should_store());
        assert!(policy.is_expired(now, now));
    }

    #[test]
    fn ttl_is_valid_before_deadline() {
        let policy = CachePolicy::Ttl(Duration::from_secs(10));
        let inserted_at = Instant::now();
        let just_before_deadline = inserted_at + Duration::from_secs(10) - Duration::from_nanos(1);

        assert!(policy.should_store());
        assert!(!policy.is_expired(inserted_at, just_before_deadline));
    }

    #[test]
    fn ttl_expires_at_exact_deadline() {
        let ttl = Duration::from_secs(10);
        let policy = CachePolicy::Ttl(ttl);
        let inserted_at = Instant::now();
        let deadline = inserted_at + ttl;

        assert!(policy.is_expired(inserted_at, deadline));
    }

    #[test]
    fn zero_ttl_expires_immediately() {
        let policy = CachePolicy::Ttl(Duration::ZERO);
        let now = Instant::now();

        assert!(policy.should_store());
        assert!(policy.is_expired(now, now));
    }

    #[test]
    fn forever_does_not_expire() {
        let policy = CachePolicy::Forever;
        let inserted_at = Instant::now();
        let much_later = inserted_at + Duration::from_secs(1_000_000);

        assert!(policy.should_store());
        assert!(!policy.is_expired(inserted_at, much_later));
    }
}
