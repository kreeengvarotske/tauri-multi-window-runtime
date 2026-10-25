//! The shared broker: verifies clients, derives the scope of every call, and
//! runs operations through `runtime_core::CachedService` (unchanged), so the
//! coalescing and cache rules are exactly the ones Core already tests.
//!
//! The cache and coalescer key of every operation is `(Scope, Params)`. The
//! scope comes from the operation registry (`Operation::SCOPE`) and the
//! verified identity, never from the request.

use crate::frame::{FrameError, read_frame, write_frame};
use crate::identity::{self, IdentityError, Manifest, VerifiedPeer};
use crate::ops::{self, Operation};
use crate::protocol::{
    ClientMessage, ErrorCode, MAX_FRAME_BYTES, NoticeEvent, OperationDescriptor, PROTOCOL_VERSION,
    RunKind, ScopeKind, ServerMessage, negotiate,
};
use crate::transport::{BoxStream, Listener, PeerInfo};
use runtime_core::{CachePolicy, CachedService};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::mpsc;
use tokio::task::AbortHandle;

#[derive(Debug, Clone)]
pub struct BrokerConfig {
    pub manifest: Manifest,
    /// Test-only delay inside every operation, to make overlap deterministic.
    /// It is not a workload and must never be used as CPU or RAM evidence.
    pub op_delay: Duration,
    pub max_in_flight: usize,
    pub max_deadline: Duration,
    pub hello_timeout: Duration,
    pub checksum_ttl: Duration,
}

impl BrokerConfig {
    pub fn new(manifest: Manifest) -> Self {
        Self {
            manifest,
            op_delay: Duration::ZERO,
            max_in_flight: 32,
            max_deadline: Duration::from_secs(30),
            hello_timeout: Duration::from_secs(5),
            checksum_ttl: Duration::from_secs(30),
        }
    }
}

/// The derived part of every key.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
enum Scope {
    Public,
    App(String),
}

impl Scope {
    fn derive(kind: ScopeKind, peer: &VerifiedPeer) -> Self {
        match kind {
            ScopeKind::Public => Self::Public,
            ScopeKind::App => Self::App(peer.app_id.clone()),
        }
    }
}

type CallFuture =
    Pin<Box<dyn Future<Output = Result<(RunKind, Value), (ErrorCode, String)>> + Send>>;
type Rejection = (ErrorCode, String);

#[derive(Default)]
struct OpCounters {
    executions: AtomicU64,
    executed: AtomicU64,
    coalesced: AtomicU64,
    cache_hits: AtomicU64,
    failures: AtomicU64,
    in_flight: AtomicU64,
}

struct InFlightGuard<'a>(&'a AtomicU64);

impl Drop for InFlightGuard<'_> {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::Relaxed);
    }
}

/// Object-safe view of one registered operation.
trait DynOp: Send + Sync {
    fn descriptor(&self) -> OperationDescriptor;
    fn start(
        self: Arc<Self>,
        peer: &VerifiedPeer,
        params: Value,
        delay: Duration,
    ) -> Result<CallFuture, Rejection>;
    fn invalidate(&self, peer: &VerifiedPeer, params: Value) -> Result<bool, Rejection>;
    fn stats(&self) -> Value;
}

struct OpHandler<O: Operation> {
    service: CachedService<(Scope, O::Params), Value, String>,
    validate: fn(&O::Params) -> Result<(), String>,
    run: fn(&O::Params, &Scope) -> Result<O::Output, String>,
    counters: OpCounters,
}

impl<O: Operation + 'static> OpHandler<O> {
    fn boxed(
        policy: CachePolicy,
        validate: fn(&O::Params) -> Result<(), String>,
        run: fn(&O::Params, &Scope) -> Result<O::Output, String>,
    ) -> Arc<dyn DynOp> {
        Arc::new(Self {
            service: CachedService::new(policy),
            validate,
            run,
            counters: OpCounters::default(),
        })
    }

    fn parse(&self, params: Value) -> Result<O::Params, Rejection> {
        let params: O::Params = serde_json::from_value(params)
            .map_err(|err| (ErrorCode::InvalidParams, err.to_string()))?;
        (self.validate)(&params).map_err(|msg| (ErrorCode::InvalidParams, msg))?;
        Ok(params)
    }
}

impl<O: Operation + 'static> DynOp for OpHandler<O> {
    fn descriptor(&self) -> OperationDescriptor {
        OperationDescriptor {
            name: O::NAME.into(),
            version: O::VERSION,
            scope: O::SCOPE,
        }
    }

    fn start(
        self: Arc<Self>,
        peer: &VerifiedPeer,
        params: Value,
        delay: Duration,
    ) -> Result<CallFuture, Rejection> {
        // Validation happens before anything runs, so invalid input never
        // reaches the operation or the counters.
        let params = self.parse(params)?;
        let scope = Scope::derive(O::SCOPE, peer);
        Ok(Box::pin(async move {
            let this = &self;
            this.counters.in_flight.fetch_add(1, Ordering::Relaxed);
            let _guard = InFlightGuard(&this.counters.in_flight);
            let key = (scope.clone(), params.clone());
            let outcome = this
                .service
                .run_with_metadata(key, || async move {
                    this.counters.executions.fetch_add(1, Ordering::Relaxed);
                    if !delay.is_zero() {
                        tokio::time::sleep(delay).await;
                    }
                    let run = this.run;
                    // The compute is synchronous; keep it off the I/O threads.
                    let output = tokio::task::spawn_blocking(move || run(&params, &scope))
                        .await
                        .map_err(|err| format!("operation task failed: {err}"))??;
                    serde_json::to_value(output).map_err(|err| err.to_string())
                })
                .await;
            let kind = RunKind::from(outcome.kind);
            match kind {
                RunKind::Executed => &this.counters.executed,
                RunKind::Coalesced => &this.counters.coalesced,
                RunKind::CacheHit => &this.counters.cache_hits,
            }
            .fetch_add(1, Ordering::Relaxed);
            match outcome.result {
                Ok(value) => Ok((kind, Value::clone(&value))),
                Err(err) => {
                    this.counters.failures.fetch_add(1, Ordering::Relaxed);
                    Err((ErrorCode::OperationFailed, String::clone(&err)))
                }
            }
        }))
    }

    fn invalidate(&self, peer: &VerifiedPeer, params: Value) -> Result<bool, Rejection> {
        let params = self.parse(params)?;
        Ok(self
            .service
            .invalidate(&(Scope::derive(O::SCOPE, peer), params)))
    }

    fn stats(&self) -> Value {
        let c = &self.counters;
        json!({
            "executions": c.executions.load(Ordering::Relaxed),
            "executed": c.executed.load(Ordering::Relaxed),
            "coalesced": c.coalesced.load(Ordering::Relaxed),
            "cacheHits": c.cache_hits.load(Ordering::Relaxed),
            "failures": c.failures.load(Ordering::Relaxed),
            "inFlight": c.in_flight.load(Ordering::Relaxed),
            "cachedEntries": self.service.cached_entries(),
        })
    }
}

fn validate_checksum(p: &ops::ChecksumParams) -> Result<(), String> {
    if p.size_kib == 0 || p.size_kib > ops::MAX_SIZE_KIB {
        return Err(format!("sizeKib must be in 1..={}", ops::MAX_SIZE_KIB));
    }
    Ok(())
}

fn run_checksum(p: &ops::ChecksumParams, _: &Scope) -> Result<ops::ChecksumOutput, String> {
    Ok(ops::checksum(p))
}

fn validate_note(p: &ops::AppNoteParams) -> Result<(), String> {
    if p.n > 1_000_000 {
        return Err("n must be at most 1000000".into());
    }
    Ok(())
}

fn run_note(p: &ops::AppNoteParams, scope: &Scope) -> Result<ops::AppNoteOutput, String> {
    // The output depends on the scope: exactly the case where a key without
    // the scope would leak one application's result to another.
    let Scope::App(app_id) = scope else {
        return Err("appNote requires an app scope".into());
    };
    Ok(ops::AppNoteOutput {
        app_id: app_id.clone(),
        n: p.n,
        note: format!("synthetic note {} for {app_id}", p.n),
    })
}

fn validate_any<T>(_: &T) -> Result<(), String> {
    Ok(())
}

fn run_fail(p: &ops::FailParams, _: &Scope) -> Result<Value, String> {
    Err(format!("synthetic failure {}", p.code))
}

struct Connection {
    app_id: String,
    peer: VerifiedPeer,
    tx: mpsc::Sender<ServerMessage>,
}

pub struct Broker {
    config: BrokerConfig,
    instance_id: String,
    ops: HashMap<(String, u16), Arc<dyn DynOp>>,
    connections: Mutex<HashMap<u64, Connection>>,
    next_conn: AtomicU64,
    active: AtomicUsize,
    last_activity: Mutex<Instant>,
}

impl Broker {
    pub fn new(config: BrokerConfig) -> Arc<Self> {
        let mut ops: HashMap<(String, u16), Arc<dyn DynOp>> = HashMap::new();
        let mut register = |op: Arc<dyn DynOp>| {
            let d = op.descriptor();
            ops.insert((d.name, d.version), op);
        };
        register(OpHandler::<ops::Checksum>::boxed(
            CachePolicy::Ttl(config.checksum_ttl),
            validate_checksum,
            run_checksum,
        ));
        register(OpHandler::<ops::AppNote>::boxed(
            CachePolicy::Forever,
            validate_note,
            run_note,
        ));
        register(OpHandler::<ops::Fail>::boxed(
            CachePolicy::Forever,
            validate_any,
            run_fail,
        ));

        Arc::new(Self {
            config,
            instance_id: new_instance_id(),
            ops,
            connections: Mutex::new(HashMap::new()),
            next_conn: AtomicU64::new(1),
            active: AtomicUsize::new(0),
            last_activity: Mutex::new(Instant::now()),
        })
    }

    pub fn instance_id(&self) -> &str {
        &self.instance_id
    }

    /// Serves until `idle_exit` passes with no connected client (if set).
    pub async fn serve(
        self: Arc<Self>,
        mut listener: Listener,
        idle_exit: Option<Duration>,
    ) -> std::io::Result<()> {
        let mut tick = tokio::time::interval(Duration::from_millis(50));
        loop {
            tokio::select! {
                accepted = listener.accept() => {
                    let (stream, peer) = accepted?;
                    self.active.fetch_add(1, Ordering::SeqCst);
                    *lock(&self.last_activity) = Instant::now();
                    let broker = Arc::clone(&self);
                    tokio::spawn(async move {
                        broker.handle(stream, peer).await;
                        broker.active.fetch_sub(1, Ordering::SeqCst);
                        *lock(&broker.last_activity) = Instant::now();
                    });
                }
                _ = tick.tick(), if idle_exit.is_some() => {
                    let idle = idle_exit.unwrap_or_default();
                    if self.active.load(Ordering::SeqCst) == 0 && lock(&self.last_activity).elapsed() >= idle {
                        return Ok(());
                    }
                }
            }
        }
    }

    async fn handle(self: &Arc<Self>, stream: BoxStream, peer_info: PeerInfo) {
        let (mut reader, mut writer) = tokio::io::split(stream);
        let (tx, mut rx) = mpsc::channel::<ServerMessage>(64);
        let writer_task = tokio::spawn(async move {
            while let Some(message) = rx.recv().await {
                if write_frame(&mut writer, &message).await.is_err() {
                    break;
                }
            }
        });

        let peer = match self.handshake(&mut reader, peer_info).await {
            Ok(peer) => peer,
            Err((code, message)) => {
                let _ = tx.send(ServerMessage::Reject { code, message }).await;
                drop(tx);
                let _ = writer_task.await;
                return;
            }
        };

        let welcome = ServerMessage::Welcome {
            protocol: PROTOCOL_VERSION,
            broker_version: env!("CARGO_PKG_VERSION").into(),
            instance_id: self.instance_id.clone(),
            app_id: peer.app_id.clone(),
            max_frame_bytes: MAX_FRAME_BYTES as u32,
            max_in_flight: self.config.max_in_flight as u32,
            // Only the operations this client may call: the list itself is
            // not shared across applications.
            operations: self
                .ops
                .values()
                .map(|op| op.descriptor())
                .filter(|d| peer.may_call(&d.name, d.version))
                .collect(),
        };
        if tx.send(welcome).await.is_err() {
            return;
        }

        let conn_id = self.next_conn.fetch_add(1, Ordering::Relaxed);
        lock(&self.connections).insert(
            conn_id,
            Connection {
                app_id: peer.app_id.clone(),
                peer: peer.clone(),
                tx: tx.clone(),
            },
        );

        let in_flight: Arc<Mutex<HashMap<u64, Option<AbortHandle>>>> = Arc::default();
        loop {
            let message: ClientMessage = match read_frame(&mut reader).await {
                Ok(message) => message,
                Err(FrameError::Closed) | Err(FrameError::Io(_)) => break,
                Err(err @ FrameError::TooLarge(_)) => {
                    let _ = tx.send(reject(ErrorCode::FrameTooLarge, err)).await;
                    break;
                }
                Err(err @ FrameError::Malformed(_)) => {
                    let _ = tx.send(reject(ErrorCode::MalformedFrame, err)).await;
                    break;
                }
            };
            match message {
                ClientMessage::Hello { .. } => {
                    let _ = tx
                        .send(reject(ErrorCode::MalformedFrame, "duplicate hello"))
                        .await;
                    break;
                }
                ClientMessage::Call {
                    id,
                    op,
                    op_version,
                    params,
                    deadline_ms,
                } => self.start_call(
                    &peer,
                    &tx,
                    &in_flight,
                    id,
                    &op,
                    op_version,
                    params,
                    deadline_ms,
                ),
                ClientMessage::Cancel { id } => {
                    if let Some(Some(handle)) = lock(&in_flight).remove(&id) {
                        handle.abort();
                    }
                }
                ClientMessage::Invalidate {
                    id,
                    op,
                    op_version,
                    params,
                } => {
                    let reply = self.invalidate(&peer, &op, op_version, params);
                    let _ = tx
                        .send(reply_message(id, reply.map(|v| (RunKind::Executed, v))))
                        .await;
                }
                ClientMessage::Stats { id } => {
                    let reply = if peer.may_read_stats() {
                        Ok((RunKind::Executed, self.stats()))
                    } else {
                        Err((ErrorCode::NotPermitted, "stats grant required".into()))
                    };
                    let _ = tx.send(reply_message(id, reply)).await;
                }
            }
        }

        // Disconnect cancels this client's calls. A call that others joined
        // keeps running for them (Core V3), and nothing is sent to anyone else.
        for (_, handle) in lock(&in_flight).drain() {
            if let Some(handle) = handle {
                handle.abort();
            }
        }
        lock(&self.connections).remove(&conn_id);
        drop(tx);
        let _ = writer_task.await;
    }

    async fn handshake<R>(
        &self,
        reader: &mut R,
        peer_info: PeerInfo,
    ) -> Result<VerifiedPeer, Rejection>
    where
        R: tokio::io::AsyncRead + Unpin,
    {
        let first = tokio::time::timeout(
            self.config.hello_timeout,
            read_frame::<_, ClientMessage>(reader),
        )
        .await
        .map_err(|_| {
            (
                ErrorCode::HelloRequired,
                "no hello before timeout".to_string(),
            )
        })?;
        let Ok(ClientMessage::Hello {
            protocol_min,
            protocol_max,
            app_id,
            ..
        }) = first
        else {
            return Err((
                ErrorCode::HelloRequired,
                "the first frame must be a hello".into(),
            ));
        };
        if negotiate(protocol_min, protocol_max).is_none() {
            return Err((
                ErrorCode::VersionMismatch,
                format!("broker speaks {PROTOCOL_VERSION}, client {protocol_min}..={protocol_max}"),
            ));
        }
        identity::verify(&self.config.manifest, &app_id, peer_info).map_err(|err| match err {
            IdentityError::NotRegistered => (
                ErrorCode::NotRegistered,
                format!("{app_id} is not registered"),
            ),
            IdentityError::Mismatch(why) => (ErrorCode::IdentityMismatch, why),
        })
    }

    #[allow(clippy::too_many_arguments)]
    fn start_call(
        self: &Arc<Self>,
        peer: &VerifiedPeer,
        tx: &mpsc::Sender<ServerMessage>,
        in_flight: &Arc<Mutex<HashMap<u64, Option<AbortHandle>>>>,
        id: u64,
        op: &str,
        op_version: u16,
        params: Value,
        deadline_ms: Option<u32>,
    ) {
        let reply_now = |code: ErrorCode, message: String| {
            let _ = tx.try_send(error_message(id, code, message));
        };
        {
            let mut table = lock(in_flight);
            if table.contains_key(&id) {
                return reply_now(
                    ErrorCode::DuplicateId,
                    format!("call {id} is already in flight"),
                );
            }
            if table.len() >= self.config.max_in_flight {
                return reply_now(ErrorCode::Busy, "too many calls in flight".into());
            }
            let future = match self.resolve(peer, op, op_version) {
                Ok(handler) => {
                    match Arc::clone(handler).start(peer, params, self.config.op_delay) {
                        Ok(future) => future,
                        Err((code, message)) => return reply_now(code, message),
                    }
                }
                Err((code, message)) => return reply_now(code, message),
            };
            table.insert(id, None);

            let deadline = deadline_ms
                .map(|ms| Duration::from_millis(u64::from(ms)))
                .unwrap_or(self.config.max_deadline)
                .min(self.config.max_deadline);
            let tx = tx.clone();
            let table_ref = Arc::clone(in_flight);
            let task = tokio::spawn(async move {
                let reply = match tokio::time::timeout(deadline, future).await {
                    Ok(reply) => reply,
                    Err(_) => Err((
                        ErrorCode::Timeout,
                        format!("deadline of {deadline:?} passed"),
                    )),
                };
                // Removed before replying: a cancel that arrives later finds
                // nothing to abort, and the client drops the reply it no longer
                // waits for.
                lock(&table_ref).remove(&id);
                let _ = tx.send(reply_message(id, reply)).await;
            });
            if let Some(slot) = table.get_mut(&id) {
                *slot = Some(task.abort_handle());
            }
        }
    }

    fn resolve(
        &self,
        peer: &VerifiedPeer,
        op: &str,
        version: u16,
    ) -> Result<&Arc<dyn DynOp>, Rejection> {
        let handler = self.ops.get(&(op.to_string(), version)).ok_or_else(|| {
            (
                ErrorCode::UnknownOperation,
                format!("{op}@{version} is not offered"),
            )
        })?;
        // An operation the client may not call looks the same as one it may
        // call but with the wrong grant only to the broker.
        if !peer.may_call(op, version) {
            return Err((
                ErrorCode::NotPermitted,
                format!("no grant for {op}@{version}"),
            ));
        }
        Ok(handler)
    }

    fn invalidate(
        &self,
        peer: &VerifiedPeer,
        op: &str,
        version: u16,
        params: Value,
    ) -> Result<Value, Rejection> {
        let handler = self.resolve(peer, op, version)?;
        if !peer.may_invalidate(op, version) {
            return Err((
                ErrorCode::NotPermitted,
                format!("no invalidate grant for {op}@{version}"),
            ));
        }
        let invalidated = handler.invalidate(peer, params)?;
        let scope = handler.descriptor().scope;
        // Tell only the clients that can read the affected scope. The notice
        // carries no key and no value.
        let event = NoticeEvent::Invalidated {
            op: op.into(),
            op_version: version,
            scope,
        };
        for conn in lock(&self.connections).values() {
            let same_scope = match scope {
                ScopeKind::Public => true,
                ScopeKind::App => conn.app_id == peer.app_id,
            };
            if same_scope && conn.peer.may_call(op, version) {
                // A hint: if the client's queue is full the notice is dropped.
                let _ = conn.tx.try_send(ServerMessage::Notice {
                    event: event.clone(),
                });
            }
        }
        Ok(json!({ "invalidated": invalidated }))
    }

    fn stats(&self) -> Value {
        let ops: serde_json::Map<String, Value> = self
            .ops
            .iter()
            .map(|((name, version), op)| (format!("{name}@{version}"), op.stats()))
            .collect();
        json!({
            "instanceId": self.instance_id,
            "connections": self.active.load(Ordering::SeqCst),
            "ops": ops,
        })
    }
}

fn reject(code: ErrorCode, message: impl ToString) -> ServerMessage {
    ServerMessage::Reject {
        code,
        message: message.to_string(),
    }
}

fn error_message(id: u64, code: ErrorCode, message: String) -> ServerMessage {
    ServerMessage::Error {
        id,
        code,
        message,
        retryable: matches!(code, ErrorCode::Busy | ErrorCode::Timeout),
    }
}

fn reply_message(id: u64, reply: Result<(RunKind, Value), Rejection>) -> ServerMessage {
    match reply {
        Ok((kind, value)) => ServerMessage::Result { id, kind, value },
        Err((code, message)) => error_message(id, code, message),
    }
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Unique enough to tell broker restarts apart; not a secret.
fn new_instance_id() -> String {
    use std::hash::{BuildHasher, Hasher};
    let mut hasher = std::collections::hash_map::RandomState::new().build_hasher();
    hasher.write_u32(std::process::id());
    hasher.write_u128(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or_default(),
    );
    format!("{:016x}", hasher.finish())
}
