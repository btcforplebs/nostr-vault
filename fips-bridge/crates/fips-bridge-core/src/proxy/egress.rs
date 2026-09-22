//! Provider side: QUIC bidi stream -> local TCP.
//!
//! One QUIC stream per inbound TCP connection, spliced byte-for-byte. Nothing
//! here parses HTTP, which is the entire point: keep-alive, byte ranges,
//! chunked encoding, the WebSocket `101` upgrade and every frame after it are
//! opaque bytes, so Blossom and the relay are the same problem solved once —
//! and the Go relay needs no changes at all.

use std::net::SocketAddr;
use std::sync::Arc;

use anyhow::{Context, Result};
use quinn::{Connection, RecvStream, SendStream};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

use crate::transport::FipsQuic;

/// Accept mesh connections forever, splicing each stream to `target`.
pub async fn serve(quic: Arc<FipsQuic>, target: SocketAddr) -> Result<()> {
    while let Some(incoming) = quic.accept().await {
        match incoming {
            Ok(connection) => {
                tokio::spawn(async move {
                    if let Err(e) = handle_connection(connection, target).await {
                        tracing::debug!("egress connection ended: {e}");
                    }
                });
            }
            Err(e) => tracing::debug!("egress accept failed: {e}"),
        }
    }
    Ok(())
}

async fn handle_connection(connection: Connection, target: SocketAddr) -> Result<()> {
    loop {
        match connection.accept_bi().await {
            Ok((send, recv)) => {
                tokio::spawn(async move {
                    if let Err(e) = splice(send, recv, target).await {
                        tracing::debug!("egress stream ended: {e}");
                    }
                });
            }
            // Peer closed, or the connection died. Either way we're done.
            Err(_) => return Ok(()),
        }
    }
}

async fn splice(mut send: SendStream, mut recv: RecvStream, target: SocketAddr) -> Result<()> {
    let tcp = TcpStream::connect(target)
        .await
        .with_context(|| format!("connect local target {target}"))?;
    let (mut tcp_read, mut tcp_write) = tcp.into_split();

    // mesh -> local
    let up = async move {
        let copied = tokio::io::copy(&mut recv, &mut tcp_write).await;
        // Half-close so the origin sees end-of-request and can respond to a
        // request that has no Content-Length.
        let _ = tcp_write.shutdown().await;
        copied
    };

    // local -> mesh
    let down = async move {
        let mut buf = vec![0u8; 64 * 1024];
        let mut total = 0u64;
        loop {
            let n = tcp_read.read(&mut buf).await?;
            if n == 0 {
                break;
            }
            send.write_all(&buf[..n]).await?;
            total += n as u64;
        }
        // Signals EOF to the consumer end of the stream.
        let _ = send.finish();
        Ok::<u64, anyhow::Error>(total)
    };

    let (up, down) = tokio::join!(up, down);
    up.context("mesh -> local copy")?;
    down.context("local -> mesh copy")?;
    Ok(())
}
