//! Length-prefixed frames: a little-endian `u32` byte count, then JSON.

use crate::protocol::MAX_FRAME_BYTES;
use serde::{Serialize, de::DeserializeOwned};
use std::io;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

#[derive(Debug)]
pub enum FrameError {
    /// The peer closed the stream between frames.
    Closed,
    TooLarge(usize),
    Malformed(serde_json::Error),
    Io(io::Error),
}

impl std::fmt::Display for FrameError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Closed => write!(f, "connection closed"),
            Self::TooLarge(len) => write!(f, "frame of {len} bytes exceeds {MAX_FRAME_BYTES}"),
            Self::Malformed(err) => write!(f, "malformed frame: {err}"),
            Self::Io(err) => write!(f, "i/o error: {err}"),
        }
    }
}

pub async fn read_frame<R, T>(reader: &mut R) -> Result<T, FrameError>
where
    R: AsyncRead + Unpin,
    T: DeserializeOwned,
{
    let mut len = [0u8; 4];
    match reader.read_exact(&mut len).await {
        Ok(_) => {}
        Err(err) if err.kind() == io::ErrorKind::UnexpectedEof => return Err(FrameError::Closed),
        Err(err) => return Err(FrameError::Io(err)),
    }
    let len = u32::from_le_bytes(len) as usize;
    // Checked before allocating, so a hostile length cannot reserve memory.
    if len > MAX_FRAME_BYTES {
        return Err(FrameError::TooLarge(len));
    }
    let mut body = vec![0u8; len];
    reader.read_exact(&mut body).await.map_err(FrameError::Io)?;
    serde_json::from_slice(&body).map_err(FrameError::Malformed)
}

pub async fn write_frame<W, T>(writer: &mut W, message: &T) -> Result<(), FrameError>
where
    W: AsyncWrite + Unpin,
    T: Serialize,
{
    let body = serde_json::to_vec(message).map_err(FrameError::Malformed)?;
    if body.len() > MAX_FRAME_BYTES {
        return Err(FrameError::TooLarge(body.len()));
    }
    writer
        .write_all(&(body.len() as u32).to_le_bytes())
        .await
        .map_err(FrameError::Io)?;
    writer.write_all(&body).await.map_err(FrameError::Io)?;
    writer.flush().await.map_err(FrameError::Io)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::ClientMessage;

    #[tokio::test]
    async fn round_trip_and_limits() {
        let (mut a, mut b) = tokio::io::duplex(64 * 1024);
        let message = ClientMessage::Cancel { id: 7 };
        write_frame(&mut a, &message).await.unwrap();
        let read: ClientMessage = read_frame(&mut b).await.unwrap();
        assert_eq!(read, message);

        // An oversized length prefix is refused before the body is read.
        a.write_all(&((MAX_FRAME_BYTES as u32) + 1).to_le_bytes())
            .await
            .unwrap();
        assert!(matches!(
            read_frame::<_, ClientMessage>(&mut b).await,
            Err(FrameError::TooLarge(_))
        ));

        drop(a);
        assert!(matches!(
            read_frame::<_, ClientMessage>(&mut b).await,
            Err(FrameError::Closed)
        ));
    }
}
