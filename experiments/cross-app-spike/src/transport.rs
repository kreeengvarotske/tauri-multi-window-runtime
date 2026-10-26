//! Local, per-user transport: a Unix domain socket on Linux and a named pipe
//! on Windows. There is no TCP listener, so nothing is reachable from the
//! network or from a browser page.
//!
//! What the transport proves about the other side is limited to what the
//! kernel reports: the peer's process id and its user (uid on Unix, the SID
//! of the process token on Windows). Turning that into an application
//! identity is `identity`'s job.

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
    /// Windows only: whether the peer process runs as the current user.
    /// `None` if the OS would not say, which callers treat as "no".
    pub same_user: Option<bool>,
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
            // The SID, not %USERNAME%: the environment is the caller's to set,
            // and names repeat across domains. The pipe namespace is shared by
            // all users, so the name alone protects nothing; see `imp`.
            let user = imp::current_sid().unwrap_or_else(|_| "user".into());
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
            same_user: None,
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
    use tokio::net::windows::named_pipe::{
        ClientOptions, NamedPipeClient, NamedPipeServer, ServerOptions,
    };
    use windows_sys::Win32::Foundation::{
        CloseHandle, ERROR_ACCESS_DENIED, ERROR_PIPE_BUSY, HANDLE, LocalFree,
    };
    use windows_sys::Win32::Security::Authorization::{
        ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW,
        SDDL_REVISION_1,
    };
    use windows_sys::Win32::Security::{
        GetTokenInformation, PSECURITY_DESCRIPTOR, SECURITY_ATTRIBUTES, TOKEN_QUERY, TOKEN_USER,
        TokenUser,
    };
    use windows_sys::Win32::System::Pipes::{
        GetNamedPipeClientProcessId, GetNamedPipeServerProcessId,
    };
    use windows_sys::Win32::System::Threading::{
        GetCurrentProcess, OpenProcess, OpenProcessToken, PROCESS_QUERY_LIMITED_INFORMATION,
    };

    /// The string SID of the user the current process runs as.
    pub fn current_sid() -> io::Result<String> {
        // SAFETY: the pseudo-handle of the current process needs no closing.
        unsafe { token_sid(GetCurrentProcess()) }
    }

    /// The string SID of the user that process `pid` runs as.
    pub fn sid_of(pid: u32) -> io::Result<String> {
        // SAFETY: plain Win32 calls; the handle is closed on every path.
        unsafe {
            let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
            if process.is_null() {
                return Err(io::Error::last_os_error());
            }
            let sid = token_sid(process);
            CloseHandle(process);
            sid
        }
    }

    unsafe fn token_sid(process: HANDLE) -> io::Result<String> {
        // SAFETY: every handle and buffer passed below is live and sized as
        // the API reports; the token handle and the SID string are freed.
        unsafe {
            let mut token: HANDLE = std::ptr::null_mut();
            if OpenProcessToken(process, TOKEN_QUERY, &mut token) == 0 {
                return Err(io::Error::last_os_error());
            }
            let mut len = 0u32;
            GetTokenInformation(token, TokenUser, std::ptr::null_mut(), 0, &mut len);
            // u64 storage keeps TOKEN_USER's pointer field aligned.
            let mut buffer = vec![0u64; (len as usize).div_ceil(8)];
            let ok =
                GetTokenInformation(token, TokenUser, buffer.as_mut_ptr().cast(), len, &mut len);
            let err = io::Error::last_os_error();
            CloseHandle(token);
            if ok == 0 {
                return Err(err);
            }
            let user = &*(buffer.as_ptr() as *const TOKEN_USER);
            let mut text = std::ptr::null_mut();
            if ConvertSidToStringSidW(user.User.Sid, &mut text) == 0 {
                return Err(io::Error::last_os_error());
            }
            let len = (0..).take_while(|&i| *text.add(i) != 0).count();
            let sid = String::from_utf16_lossy(std::slice::from_raw_parts(text, len));
            LocalFree(text.cast());
            Ok(sid)
        }
    }

    fn same_user(pid: Option<u32>) -> Option<bool> {
        let pid = pid?;
        Some(sid_of(pid).ok()? == current_sid().ok()?)
    }

    /// Creates one pipe instance whose DACL lets only the current user in.
    /// The default DACL would also give Everyone read access.
    fn create_instance(name: &OsString, first: bool) -> io::Result<NamedPipeServer> {
        let sid = current_sid()?;
        let sddl: Vec<u16> = format!("D:P(A;;GA;;;{sid})")
            .encode_utf16()
            .chain(Some(0))
            .collect();
        let mut descriptor: PSECURITY_DESCRIPTOR = std::ptr::null_mut();
        // SAFETY: `sddl` is NUL-terminated; the descriptor is freed below,
        // after the pipe was created with a copy of it.
        unsafe {
            if ConvertStringSecurityDescriptorToSecurityDescriptorW(
                sddl.as_ptr(),
                SDDL_REVISION_1,
                &mut descriptor,
                std::ptr::null_mut(),
            ) == 0
            {
                return Err(io::Error::last_os_error());
            }
            let mut attributes = SECURITY_ATTRIBUTES {
                nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
                lpSecurityDescriptor: descriptor,
                bInheritHandle: 0,
            };
            // `first_pipe_instance` makes creation fail if any process already
            // created this pipe: one broker per name. tokio rejects remote
            // (SMB) clients by default; it is set explicitly anyway.
            let created = ServerOptions::new()
                .first_pipe_instance(first)
                .reject_remote_clients(true)
                .create_with_security_attributes_raw(
                    name,
                    (&mut attributes as *mut SECURITY_ATTRIBUTES).cast(),
                );
            LocalFree(descriptor);
            created
        }
    }

    pub struct Listener {
        name: OsString,
        next: NamedPipeServer,
    }

    impl Listener {
        pub fn bind(endpoint: &Endpoint) -> io::Result<Self> {
            // ERROR_ACCESS_DENIED here means the name exists: another broker,
            // or another user squatting it. Either way we must not serve.
            let next = create_instance(&endpoint.0, true).map_err(|err| {
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
            let connected = self.next.connect().await;
            // A fresh instance either way: after a failed connect (for example
            // a client that is already gone) the old one is unusable.
            let fresh = create_instance(&self.name, false)?;
            let server = std::mem::replace(&mut self.next, fresh);
            connected?;
            let mut pid = 0u32;
            // SAFETY: the handle is a live named-pipe server handle.
            let ok = unsafe { GetNamedPipeClientProcessId(server.as_raw_handle() as _, &mut pid) };
            let pid = (ok != 0).then_some(pid);
            let peer = PeerInfo {
                pid,
                uid: None,
                same_user: same_user(pid),
            };
            Ok((Box::new(server), peer))
        }
    }

    pub async fn connect(endpoint: &Endpoint) -> io::Result<(BoxStream, PeerInfo)> {
        let mut attempts = 0;
        let client: NamedPipeClient = loop {
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
        let pid = (ok != 0).then_some(pid);
        let peer = PeerInfo {
            pid,
            uid: None,
            same_user: same_user(pid),
        };
        Ok((Box::new(client), peer))
    }
}

pub use imp::{Listener, connect};

#[cfg(unix)]
pub use imp::current_uid;
#[cfg(windows)]
pub use imp::{current_sid, sid_of};
