//! Typed client library: what a Tauri app's Rust side would embed.
//!
//! The client never computes a scope or sends one. It verifies the server
//! side of the connection as far as the OS allows (same uid on Linux), and it
//! drops any reply it is no longer waiting for, so a cancelled or timed-out
//! call can never surface a late result.

use crate::frame::{read_frame, write_frame};
use crate::ops::Operation;
use crate::protocol::{
    ClientMessage, ErrorCode, NoticeEvent, OperationDescriptor, PROTOCOL_VERSION, RunKind,
    ServerMessage,
};
use crate::transport::{self, Endpoint};
use serde_json::Value;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};

#[derive(Debug, Clone, PartialEq)]
pub enum ClientError {
    /// The broker refused the handshake.
    Rejected {
        code: ErrorCode,
        message: String,
    },
    /// The broker answered the call with an error.
    Remote {
        code: ErrorCode,
        message: String,
        retryable: bool,
    },
    /// No broker, or the connection was lost. In-flight calls fail with this;
    /// the caller decides whether to reconnect and retry.
    BrokerUnavailable(String),
    Protocol(String),
}

impl ClientError {
    pub fn code(&self) -> ErrorCode {
        match self {
            Self::Rejected { code, .. } | Self::Remote { code, .. } => *code,
            Self::BrokerUnavailable(_) => ErrorCode::BrokerUnavailable,
            Self::Protocol(_) => ErrorCode::MalformedFrame,
        }
    }
}

impl std::fmt::Display for ClientError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}

#[derive(Debug, Clone)]
pub struct Welcome {
    pub protocol: u16,
    pub broker_version: String,
    pub instance_id: String,
    pub app_id: String,
    pub max_in_flight: u32,
    pub operations: Vec<OperationDescriptor>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct CallOk<T> {
    pub kind: RunKind,
    pub value: T,
}

type Reply = Result<(RunKind, Value), ClientError>;
/// `None` once the connection is gone, so a call registered after that
/// fails at once instead of waiting forever.
type Pending = Arc<Mutex<Option<HashMap<u64, oneshot::Sender<Reply>>>>>;

pub struct Client {
    welcome: Welcome,
    tx: mpsc::Sender<ClientMessage>,
    pending: Pending,
    next_id: AtomicU64,
    notices: tokio::sync::Mutex<mpsc::Receiver<NoticeEvent>>,
    late_replies: Arc<AtomicU64>,
}

/// A call started with `Client::start`; `wait` or `Client::cancel` it.
pub struct PendingCall<O: Operation> {
    pub id: u64,
    rx: oneshot::Receiver<Reply>,
    _op: std::marker::PhantomData<O>,
}

impl<O: Operation> PendingCall<O> {
    pub async fn wait(self) -> Result<CallOk<O::Output>, ClientError> {
        let (kind, value) = self.rx.await.map_err(|_| {
            ClientError::BrokerUnavailable("call was cancelled or the connection closed".into())
        })??;
        let value =
            serde_json::from_value(value).map_err(|err| ClientError::Protocol(err.to_string()))?;
        Ok(CallOk { kind, value })
    }
}

impl Client {
    pub async fn connect(endpoint: &Endpoint, app_id: &str) -> Result<Self, ClientError> {
        Self::connect_with_versions(endpoint, app_id, PROTOCOL_VERSION, PROTOCOL_VERSION).await
    }

    pub async fn connect_with_versions(
        endpoint: &Endpoint,
        app_id: &str,
        protocol_min: u16,
        protocol_max: u16,
    ) -> Result<Self, ClientError> {
        let (stream, server) = transport::connect(endpoint)
            .await
            .map_err(|err| ClientError::BrokerUnavailable(err.to_string()))?;
        #[cfg(unix)]
        {
            // Do not talk to a broker that runs as someone else.
            let own =
                transport::current_uid().map_err(|err| ClientError::Protocol(err.to_string()))?;
            if server.uid != Some(own) {
                return Err(ClientError::Protocol(format!(
                    "broker uid {:?} is not {own}",
                    server.uid
                )));
            }
        }
        #[cfg(windows)]
        if server.same_user != Some(true) {
            // The pipe namespace is shared by all users: another user may have
            // created this name first. Do not talk to a broker we cannot
            // prove runs as us.
            return Err(ClientError::Protocol(format!(
                "broker pid {:?} does not run as the current user",
                server.pid
            )));
        }

        let (mut reader, mut writer) = tokio::io::split(stream);
        let hello = ClientMessage::Hello {
            protocol_min,
            protocol_max,
            sdk: concat!("cross-app-spike/", env!("CARGO_PKG_VERSION")).into(),
            app_id: app_id.into(),
        };
        write_frame(&mut writer, &hello)
            .await
            .map_err(|err| ClientError::BrokerUnavailable(err.to_string()))?;
        let welcome = match read_frame::<_, ServerMessage>(&mut reader).await {
            Ok(ServerMessage::Welcome {
                protocol,
                broker_version,
                instance_id,
                app_id,
                max_in_flight,
                operations,
                ..
            }) => Welcome {
                protocol,
                broker_version,
                instance_id,
                app_id,
                max_in_flight,
                operations,
            },
            Ok(ServerMessage::Reject { code, message }) => {
                return Err(ClientError::Rejected { code, message });
            }
            Ok(other) => {
                return Err(ClientError::Protocol(format!(
                    "expected welcome, got {other:?}"
                )));
            }
            Err(err) => return Err(ClientError::BrokerUnavailable(err.to_string())),
        };

        let (tx, mut out_rx) = mpsc::channel::<ClientMessage>(64);
        tokio::spawn(async move {
            while let Some(message) = out_rx.recv().await {
                if write_frame(&mut writer, &message).await.is_err() {
                    break;
                }
            }
        });

        let pending: Pending = Arc::new(Mutex::new(Some(HashMap::new())));
        let late_replies = Arc::new(AtomicU64::new(0));
        let (notice_tx, notice_rx) = mpsc::channel(64);
        {
            let pending = Arc::clone(&pending);
            let late_replies = Arc::clone(&late_replies);
            tokio::spawn(async move {
                let reason = loop {
                    let message = match read_frame::<_, ServerMessage>(&mut reader).await {
                        Ok(message) => message,
                        Err(err) => break err.to_string(),
                    };
                    let (id, reply) = match message {
                        ServerMessage::Result { id, kind, value } => (id, Ok((kind, value))),
                        ServerMessage::Error {
                            id,
                            code,
                            message,
                            retryable,
                        } => (
                            id,
                            Err(ClientError::Remote {
                                code,
                                message,
                                retryable,
                            }),
                        ),
                        ServerMessage::Notice { event } => {
                            let _ = notice_tx.try_send(event);
                            continue;
                        }
                        ServerMessage::Reject { code, message } => {
                            break format!("{code:?}: {message}");
                        }
                        ServerMessage::Welcome { .. } => break "unexpected second welcome".into(),
                    };
                    match lock(&pending).as_mut().and_then(|p| p.remove(&id)) {
                        Some(waiter) => {
                            let _ = waiter.send(reply);
                        }
                        // Cancelled or timed out on this side: never delivered.
                        None => {
                            late_replies.fetch_add(1, Ordering::Relaxed);
                        }
                    }
                };
                let waiters = lock(&pending).take().unwrap_or_default();
                for (_, waiter) in waiters {
                    let _ = waiter.send(Err(ClientError::BrokerUnavailable(reason.clone())));
                }
            });
        }

        Ok(Self {
            welcome,
            tx,
            pending,
            next_id: AtomicU64::new(1),
            notices: tokio::sync::Mutex::new(notice_rx),
            late_replies,
        })
    }

    pub fn welcome(&self) -> &Welcome {
        &self.welcome
    }

    /// Replies that arrived for calls this client had already given up on.
    pub fn late_replies_dropped(&self) -> u64 {
        self.late_replies.load(Ordering::Relaxed)
    }

    pub async fn call<O: Operation>(
        &self,
        params: &O::Params,
    ) -> Result<CallOk<O::Output>, ClientError> {
        self.start::<O>(params, None).await?.wait().await
    }

    pub async fn start<O: Operation>(
        &self,
        params: &O::Params,
        deadline: Option<Duration>,
    ) -> Result<PendingCall<O>, ClientError> {
        let params =
            serde_json::to_value(params).map_err(|err| ClientError::Protocol(err.to_string()))?;
        let (id, rx) = self.register()?;
        self.send(ClientMessage::Call {
            id,
            op: O::NAME.into(),
            op_version: O::VERSION,
            params,
            deadline_ms: deadline.map(|d| d.as_millis().min(u128::from(u32::MAX)) as u32),
        })
        .await?;
        Ok(PendingCall {
            id,
            rx,
            _op: std::marker::PhantomData,
        })
    }

    /// Stops waiting for `id` and asks the broker to cancel it.
    pub async fn cancel(&self, id: u64) -> Result<(), ClientError> {
        if let Some(pending) = lock(&self.pending).as_mut() {
            pending.remove(&id);
        }
        self.send(ClientMessage::Cancel { id }).await
    }

    pub async fn invalidate<O: Operation>(&self, params: &O::Params) -> Result<bool, ClientError> {
        let params =
            serde_json::to_value(params).map_err(|err| ClientError::Protocol(err.to_string()))?;
        let (id, rx) = self.register()?;
        self.send(ClientMessage::Invalidate {
            id,
            op: O::NAME.into(),
            op_version: O::VERSION,
            params,
        })
        .await?;
        let (_, value) = Self::await_reply(rx).await?;
        Ok(value
            .get("invalidated")
            .and_then(Value::as_bool)
            .unwrap_or(false))
    }

    pub async fn stats(&self) -> Result<Value, ClientError> {
        let (id, rx) = self.register()?;
        self.send(ClientMessage::Stats { id }).await?;
        Ok(Self::await_reply(rx).await?.1)
    }

    pub async fn next_notice(&self, wait: Duration) -> Option<NoticeEvent> {
        let mut notices = self.notices.lock().await;
        tokio::time::timeout(wait, notices.recv())
            .await
            .ok()
            .flatten()
    }

    /// An untyped call, for callers that build requests at run time (and for
    /// tests that check what the broker refuses).
    pub async fn call_raw(
        &self,
        op: &str,
        op_version: u16,
        params: Value,
    ) -> Result<(RunKind, Value), ClientError> {
        let (id, rx) = self.register()?;
        self.send(ClientMessage::Call {
            id,
            op: op.into(),
            op_version,
            params,
            deadline_ms: None,
        })
        .await?;
        Self::await_reply(rx).await
    }

    fn register(&self) -> Result<(u64, oneshot::Receiver<Reply>), ClientError> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        lock(&self.pending)
            .as_mut()
            .ok_or_else(|| ClientError::BrokerUnavailable("connection closed".into()))?
            .insert(id, tx);
        Ok((id, rx))
    }

    async fn send(&self, message: ClientMessage) -> Result<(), ClientError> {
        self.tx
            .send(message)
            .await
            .map_err(|_| ClientError::BrokerUnavailable("connection closed".into()))
    }

    async fn await_reply(rx: oneshot::Receiver<Reply>) -> Reply {
        rx.await
            .map_err(|_| ClientError::BrokerUnavailable("connection closed".into()))?
    }
}

/// Reconnects after a lost broker and retries. Only valid because every
/// shared operation is deterministic and idempotent (an ADR requirement).
pub struct Session {
    endpoint: Endpoint,
    app_id: String,
    client: Option<Client>,
    pub reconnects: u32,
}

impl Session {
    pub fn new(endpoint: Endpoint, app_id: impl Into<String>) -> Self {
        Self {
            endpoint,
            app_id: app_id.into(),
            client: None,
            reconnects: 0,
        }
    }

    pub fn client(&self) -> Option<&Client> {
        self.client.as_ref()
    }

    pub async fn call<O: Operation>(
        &mut self,
        params: &O::Params,
        attempts: u32,
    ) -> Result<CallOk<O::Output>, ClientError> {
        let mut backoff = Duration::from_millis(50);
        let mut last = ClientError::BrokerUnavailable("no attempt made".into());
        for attempt in 0..attempts.max(1) {
            if self.client.is_none() {
                match Client::connect(&self.endpoint, &self.app_id).await {
                    Ok(client) => {
                        if attempt > 0 {
                            self.reconnects += 1;
                        }
                        self.client = Some(client);
                    }
                    Err(err @ ClientError::BrokerUnavailable(_)) => {
                        last = err;
                        tokio::time::sleep(backoff).await;
                        backoff = (backoff * 2).min(Duration::from_secs(1));
                        continue;
                    }
                    Err(err) => return Err(err),
                }
            }
            let client = self.client.as_ref().expect("connected above");
            match client.call::<O>(params).await {
                Err(err @ ClientError::BrokerUnavailable(_)) => {
                    self.client = None;
                    last = err;
                }
                other => return other,
            }
        }
        Err(last)
    }
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}
