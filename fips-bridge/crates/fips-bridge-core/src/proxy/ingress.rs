//! Consumer side: loopback TCP listener -> QUIC bidi stream.
//!
//! This is what makes the whole client-side problem disappear. `.fips` URLs are
//! rewritten to `http://127.0.0.1:<port>/...`, and then SwiftUI's `AsyncImage`,
//! `AVURLAsset`, Coil, ExoPlayer and every `URLSession` just work — no
//! `URLProtocol`, no `AVAssetResourceLoaderDelegate`, no per-call-site
//! interception. They are all talking to what looks like an ordinary HTTP origin.

use std::sync::Arc;

use anyhow::{Context, Result};
use fips_endpoint::PeerIdentity;
use quinn::Connection;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::Mutex;

use crate::transport::FipsQuic;

/// A loopback listener bound to one remote peer.
///
/// Port-per-peer rather than path-prefix routing: the request path, method,
/// headers and body all reach the origin untouched. A path prefix would break
/// relative `Location:` headers and Blossom's self-referential BUD-02
/// descriptors, and would mangle the sha256 path shape the Go relay's blob
/// regex matches on.
pub struct Ingress {
    quic: Arc<FipsQuic>,
    peer: PeerIdentity,
    connection: Mutex<Option<Connection>>,
}

impl Ingress {
    pub fn new(quic: Arc<FipsQuic>, peer: PeerIdentity) -> Arc<Self> {
        Arc::new(Self {
            quic,
            peer,
            connection: Mutex::new(None),
        })
    }

    /// Reuse the live connection, redialing only if it has closed. quinn
    /// multiplexes streams over one connection, so this is the common path.
    async fn connection(&self) -> Result<Connection> {
        let mut guard = self.connection.lock().await;
        if let Some(existing) = guard.as_ref() {
            if existing.close_reason().is_none() {
                return Ok(existing.clone());
            }
        }
        let fresh = self
            .quic
            .connect(self.peer.clone())
            .await
            .context("dial peer over mesh")?;
        *guard = Some(fresh.clone());
        Ok(fresh)
    }

    /// Serve the listener until it errors.
    pub async fn serve(self: Arc<Self>, listener: TcpListener) -> Result<()> {
        loop {
            let (tcp, _) = listener.accept().await.context("accept loopback")?;
            let this = self.clone();
            tokio::spawn(async move {
                if let Err(e) = this.handle(tcp).await {
                    tracing::debug!("ingress connection ended: {e}");
                }
            });
        }
    }

    async fn handle(&self, tcp: TcpStream) -> Result<()> {
        let connection = self.connection().await?;
        let (mut send, mut recv) = connection.open_bi().await.context("open_bi")?;
        let (mut tcp_read, mut tcp_write) = tcp.into_split();

        // local -> mesh
        let up = async move {
            let mut buf = vec![0u8; 64 * 1024];
            loop {
                let n = tcp_read.read(&mut buf).await?;
                if n == 0 {
                    break;
                }
                send.write_all(&buf[..n]).await?;
            }
            let _ = send.finish();
            Ok::<(), anyhow::Error>(())
        };

        // mesh -> local
        let down = async move {
            let copied = tokio::io::copy(&mut recv, &mut tcp_write).await;
            let _ = tcp_write.shutdown().await;
            copied
        };

        let (up, down) = tokio::join!(up, down);
        up.context("local -> mesh copy")?;
        down.context("mesh -> local copy")?;
        Ok(())
    }
}
