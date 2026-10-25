//! Local, per-user transport: a Unix domain socket on Linux and a named pipe
//! on Windows. There is no TCP listener, so nothing is reachable from the
//! network or from a browser page.
//!
//! What the transport proves about the other side is limited to what the
//! kernel reports: the peer's process id and, on Unix, its user id. Turning
//! that into an application identity is `identity`'s job.

use std::ffi::OsString;
use std::io;
#[cfg(unix)]
use std::path::PathBuf;
use tokio::io::{AsyncRead, AsyncWrite};

pub trait Stream: AsyncRead + AsyncWrite + Send + Unpin {}
impl<T: AsyncRead + AsyncWrite + Send + Unpin> Stream for T {}

pub type BoxStream = Box<dyn Stream>;

/// What the OS says about the peer of a connection.
#[derive(Debug, Clone, Copy, Default)]
pub struct PeerInfo {
    pub pid: Option<u32>,
    /// Unix only.
    pub uid: Option<u32>,
}

/// A socket path on Unix, a pipe name (`\\.\pipe\...`) on Windows.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Endpoint(pub OsString);

impl Endpoint {
    pub fn new(value: impl Into<OsString>) -> Self {
        Self(value.into())
    }

    /// A per-user default for manual runs.
    pub fn default_for_user() -> Self {
        #[cfg(windows)]
        {
            let user = std::env::var("USERNAME").unwrap_or_else(|_| "user".into());
            Self::new(format!(r"\\.\pipe\tmwr-spike-{user}"))
        }
        #[cfg(unix)]
        {
            let base = std::env::var_os("XDG_RUNTIME_DIR")
                .map(PathBuf::from)
                .unwrap_or_else(std::env::temp_dir);
            Self::new(base.join("tmwr-spike").join("broker.sock"))
        }
    }
}

/// Returned by `Listener::bind` when another broker owns the endpoint.
pub fn is_already_running(err: &io::Error) -> bool {
    err.kind() == io::ErrorKind::AddrInUse
}

#[cfg(unix)]
mod imp {
    use super::*;
    use std::fs::{self, File, OpenOptions};
    use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
    use std::path::Path;
    use tokio::net::{UnixListener, UnixStream};

    pub fn current_uid() -> io::Result<u32> {
        if cfg!(target_os = "linux") {
            Ok(fs::metadata("/proc/self")?.uid())
        } else {
            Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "the spike only implements Linux on Unix",
            ))
        }
    }

    pub struct Listener {
        listener: UnixListener,
        path: PathBuf,
        // Held for the broker's lifetime; the kernel drops it on crash, so a
        // stale lock cannot block a restart.
        _lock: File,
    }

    impl Listener {
        pub fn bind(endpoint: &Endpoint) -> io::Result<Self> {
            let uid = current_uid()?;
            let path = PathBuf::from(&endpoint.0);
            let dir = path
                .parent()
                .filter(|p| !p.as_os_str().is_empty())
                .ok_or_else(|| {
                    io::Error::new(io::ErrorKind::InvalidInput, "no socket directory")
                })?;
            fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(dir)?;
            let meta = fs::metadata(dir)?;
            // Refuse a directory someone else owns or can write to: they could
            // replace the socket with their own (endpoint squatting).
            if meta.uid() != uid || meta.permissions().mode() & 0o022 != 0 {
                return Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    format!(
                        "{} must be owned by uid {uid} and not group/world writable",
                        dir.display()
                    ),
                ));
            }

            let lock = OpenOptions::new()
                .create(true)
                .truncate(false)
                .write(true)
                .open(lock_path(&path))?;
            match lock.try_lock() {
                Ok(()) => {}
                Err(fs::TryLockError::WouldBlock) => {
                    return Err(io::Error::new(
                        io::ErrorKind::AddrInUse,
                        "broker already running",
                    ));
                }
                Err(fs::TryLockError::Error(err)) => return Err(err),
            }
            // We own the lock, so any socket file left here is stale.
            match fs::remove_file(&path) {
                Ok(()) => {}
                Err(err) if err.kind() == io::ErrorKind::NotFound => {}
                Err(err) => return Err(err),
            }
            let listener = UnixListener::bind(&path)?;
            fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
            Ok(Self {
                listener,
                path,
                _lock: lock,
            })
        }

        pub async fn accept(&mut self) -> io::Result<(BoxStream, PeerInfo)> {
            let (stream, _) = self.listener.accept().await?;
            let peer = peer_of(&stream)?;
            Ok((Box::new(stream), peer))
        }
    }

    impl Drop for Listener {
        fn drop(&mut self) {
            let _ = fs::remove_file(&self.path);
        }
    }

    fn lock_path(socket: &Path) -> PathBuf {
        let mut name = socket.as_os_str().to_owned();
        name.push(".lock");
        PathBuf::from(name)
    }

    fn peer_of(stream: &UnixStream) -> io::Result<PeerInfo> {
        let cred = stream.peer_cred()?;
        Ok(PeerInfo {
            pid: cred.pid().and_then(|pid| u32::try_from(pid).ok()),
            uid: Some(cred.uid()),
        })
    }

    pub async fn connect(endpoint: &Endpoint) -> io::Result<(BoxStream, PeerInfo)> {
        let stream = UnixStream::connect(PathBuf::from(&endpoint.0)).await?;
        let peer = peer_of(&stream)?;
        Ok((Box::new(stream), peer))
    }
}

#[cfg(windows)]
mod imp {
    use super::*;
    use std::os::windows::io::AsRawHandle;
    use tokio::net::windows::named_pipe::{ClientOptions, NamedPipeServer, ServerOptions};
    use windows_sys::Win32::Foundation::{ERROR_ACCESS_DENIED, ERROR_PIPE_BUSY};
    use windows_sys::Win32::System::Pipes::{
        GetNamedPipeClientProcessId, GetNamedPipeServerProcessId,
    };

    pub struct Listener {
        name: OsString,
        next: NamedPipeServer,
    }

    impl Listener {
        pub fn bind(endpoint: &Endpoint) -> io::Result<Self> {
            // `first_pipe_instance` makes creation fail if any process already
            // created this pipe: one broker per name, and no silent squatting.
            // tokio rejects remote (SMB) clients by default.
            let next = ServerOptions::new()
                .first_pipe_instance(true)
                .reject_remote_clients(true)
                .create(&endpoint.0)
                .map_err(|err| {
                    if err.raw_os_error() == Some(ERROR_ACCESS_DENIED as i32) {
                        io::Error::new(io::ErrorKind::AddrInUse, "broker already running")
                    } else {
                        err
                    }
                })?;
            Ok(Self {
                name: endpoint.0.clone(),
                next,
            })
        }

        pub async fn accept(&mut self) -> io::Result<(BoxStream, PeerInfo)> {
            self.next.connect().await?;
            let fresh = ServerOptions::new()
                .reject_remote_clients(true)
                .create(&self.name)?;
            let connected = std::mem::replace(&mut self.next, fresh);
            let mut pid = 0u32;
            // SAFETY: the handle is a live named-pipe server handle.
            let ok =
                unsafe { GetNamedPipeClientProcessId(connected.as_raw_handle() as _, &mut pid) };
            let peer = PeerInfo {
                pid: (ok != 0).then_some(pid),
                uid: None,
            };
            Ok((Box::new(connected), peer))
        }
    }

    pub async fn connect(endpoint: &Endpoint) -> io::Result<(BoxStream, PeerInfo)> {
        let mut attempts = 0;
        let client = loop {
            match ClientOptions::new().open(&endpoint.0) {
                Ok(client) => break client,
                Err(err) if err.raw_os_error() == Some(ERROR_PIPE_BUSY as i32) && attempts < 50 => {
                    attempts += 1;
                    tokio::time::sleep(std::time::Duration::from_millis(20)).await;
                }
                Err(err) => return Err(err),
            }
        };
        let mut pid = 0u32;
        // SAFETY: the handle is a live named-pipe client handle.
        let ok = unsafe { GetNamedPipeServerProcessId(client.as_raw_handle() as _, &mut pid) };
        let peer = PeerInfo {
            pid: (ok != 0).then_some(pid),
            uid: None,
        };
        Ok((Box::new(client), peer))
    }
}

pub use imp::{Listener, connect};

#[cfg(unix)]
pub use imp::current_uid;
