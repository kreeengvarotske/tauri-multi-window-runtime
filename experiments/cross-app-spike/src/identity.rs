//! Client identity for the spike. **Provisional, not a Group 1 decision.**
//!
//! A client is accepted only if all of these hold:
//! 1. it connected over the per-user local endpoint (and, on Linux, the
//!    kernel-reported uid equals the broker's uid);
//! 2. its claimed `appId` is in the broker's manifest;
//! 3. the executable of the connecting process, looked up by the broker from
//!    the kernel-reported pid, is the executable the manifest registers for
//!    that `appId`.
//!
//! What this does not prove: a process of the same OS user can still pretend
//! (for example by passing the connected socket to another process, or by
//! injecting code into a registered binary). That is why only data that is
//! safe to show to any process of the same user may enter the shared broker.

use crate::transport::PeerInfo;
use serde::Deserialize;
use std::collections::BTreeSet;
use std::io;
use std::path::{Path, PathBuf};

/// The synthetic registration file the broker is started with.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Manifest {
    pub apps: Vec<AppRegistration>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AppRegistration {
    pub app_id: String,
    pub executable: PathBuf,
    /// `op@version` to call, `invalidate:op@version`, and `stats`.
    pub grants: BTreeSet<String>,
}

impl Manifest {
    pub fn load(path: &Path) -> io::Result<Self> {
        let text = std::fs::read_to_string(path)?;
        serde_json::from_str(&text).map_err(|err| io::Error::new(io::ErrorKind::InvalidData, err))
    }
}

/// An identity the broker verified. Only the broker constructs it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VerifiedPeer {
    pub app_id: String,
    pub grants: BTreeSet<String>,
}

impl VerifiedPeer {
    pub fn may_call(&self, op: &str, version: u16) -> bool {
        self.grants.contains(&format!("{op}@{version}"))
    }

    pub fn may_invalidate(&self, op: &str, version: u16) -> bool {
        self.grants.contains(&format!("invalidate:{op}@{version}"))
    }

    pub fn may_read_stats(&self) -> bool {
        self.grants.contains("stats")
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum IdentityError {
    NotRegistered,
    Mismatch(String),
}

pub fn verify(
    manifest: &Manifest,
    claimed_app_id: &str,
    peer: PeerInfo,
) -> Result<VerifiedPeer, IdentityError> {
    let registration = manifest
        .apps
        .iter()
        .find(|app| app.app_id == claimed_app_id)
        .ok_or(IdentityError::NotRegistered)?;

    #[cfg(unix)]
    {
        let own = crate::transport::current_uid()
            .map_err(|err| IdentityError::Mismatch(err.to_string()))?;
        if peer.uid != Some(own) {
            return Err(IdentityError::Mismatch(format!(
                "peer uid {:?} is not {own}",
                peer.uid
            )));
        }
    }

    let pid = peer
        .pid
        .ok_or_else(|| IdentityError::Mismatch("the OS did not report a peer pid".into()))?;
    let actual =
        executable_of(pid).map_err(|err| IdentityError::Mismatch(format!("pid {pid}: {err}")))?;
    let expected = std::fs::canonicalize(&registration.executable)
        .map_err(|err| IdentityError::Mismatch(format!("registered executable: {err}")))?;
    if actual != expected {
        return Err(IdentityError::Mismatch(format!(
            "pid {pid} runs {}, not the executable registered for {claimed_app_id}",
            actual.display()
        )));
    }

    Ok(VerifiedPeer {
        app_id: registration.app_id.clone(),
        grants: registration.grants.clone(),
    })
}

/// The canonical path of the executable a process runs.
pub fn executable_of(pid: u32) -> io::Result<PathBuf> {
    #[cfg(target_os = "linux")]
    {
        // A deleted or replaced binary reads as "... (deleted)" and fails the match.
        std::fs::read_link(format!("/proc/{pid}/exe")).and_then(std::fs::canonicalize)
    }
    #[cfg(windows)]
    {
        windows_image_path(pid).and_then(std::fs::canonicalize)
    }
    #[cfg(not(any(target_os = "linux", windows)))]
    {
        let _ = pid;
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "not implemented on this OS",
        ))
    }
}

#[cfg(windows)]
fn windows_image_path(pid: u32) -> io::Result<PathBuf> {
    use std::ffi::OsString;
    use std::os::windows::ffi::OsStringExt;
    use windows_sys::Win32::Foundation::CloseHandle;
    use windows_sys::Win32::System::Threading::{
        OpenProcess, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION,
        QueryFullProcessImageNameW,
    };

    // SAFETY: plain Win32 calls; the handle is closed on every path.
    unsafe {
        let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if handle.is_null() {
            return Err(io::Error::last_os_error());
        }
        let mut buffer = vec![0u16; 32_768];
        let mut len = buffer.len() as u32;
        let ok =
            QueryFullProcessImageNameW(handle, PROCESS_NAME_WIN32, buffer.as_mut_ptr(), &mut len);
        let err = io::Error::last_os_error();
        CloseHandle(handle);
        if ok == 0 {
            return Err(err);
        }
        Ok(PathBuf::from(OsString::from_wide(&buffer[..len as usize])))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn manifest_for(exe: PathBuf) -> Manifest {
        Manifest {
            apps: vec![AppRegistration {
                app_id: "demo.alpha".into(),
                executable: exe,
                grants: ["fixture.checksum@1".to_string()].into(),
            }],
        }
    }

    #[test]
    fn unknown_app_is_not_registered() {
        let manifest = manifest_for(std::env::current_exe().unwrap());
        let peer = PeerInfo {
            pid: Some(std::process::id()),
            uid: None,
        };
        assert_eq!(
            verify(&manifest, "demo.beta", peer),
            Err(IdentityError::NotRegistered)
        );
    }

    #[cfg(any(target_os = "linux", windows))]
    #[test]
    fn executable_must_match_registration() {
        let me = std::env::current_exe().unwrap();
        let peer = PeerInfo {
            pid: Some(std::process::id()),
            #[cfg(unix)]
            uid: Some(crate::transport::current_uid().unwrap()),
            #[cfg(not(unix))]
            uid: None,
        };
        let ok = verify(&manifest_for(me.clone()), "demo.alpha", peer).unwrap();
        assert!(ok.may_call("fixture.checksum", 1));
        assert!(!ok.may_call("fixture.checksum", 2));
        assert!(!ok.may_read_stats());

        // The same claim from a process that runs a different binary fails.
        let other = me.parent().unwrap().join("not-this-binary");
        std::fs::write(&other, b"").unwrap();
        let err = verify(&manifest_for(other.clone()), "demo.alpha", peer).unwrap_err();
        assert!(matches!(err, IdentityError::Mismatch(_)), "{err:?}");
        let _ = std::fs::remove_file(other);
    }

    #[cfg(unix)]
    #[test]
    fn missing_or_foreign_uid_is_rejected() {
        let manifest = manifest_for(std::env::current_exe().unwrap());
        let me = crate::transport::current_uid().unwrap();
        for uid in [None, Some(me.wrapping_add(1))] {
            let peer = PeerInfo {
                pid: Some(std::process::id()),
                uid,
            };
            assert!(matches!(
                verify(&manifest, "demo.alpha", peer),
                Err(IdentityError::Mismatch(_))
            ));
        }
    }
}
