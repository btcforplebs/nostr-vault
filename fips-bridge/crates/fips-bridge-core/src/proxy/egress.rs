//! Provider side: QUIC bidi stream -> local TCP.
//!
//! One QUIC stream per inbound TCP connection, spliced byte-for-byte. Nothing
//! here parses HTTP, which is the entire point: keep-alive, byte ranges,
//! chunked encoding, the WebSocket `101` upgrade and every frame after it are
//! opaque bytes, so Blossom and the relay are the same problem solved once —
//! and the Go relay needs no changes at all.

use std::collections::HashSet;
use std::net::{IpAddr, Ipv6Addr, SocketAddr};
use std::sync::Arc;

use anyhow::{bail, Context, Result};
use fips_endpoint::PeerIdentity;
use quinn::{Connection, RecvStream, SendStream};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

use crate::transport::addr_map::AddrMap;
use crate::transport::FipsQuic;

/// The npubs allowed to open streams through an egress.
///
/// `serve` splices every peer FIPS authenticated, which is right for a vault
/// shared with the whole mesh but wrong in front of something private like an
/// LND REST port: any npub on the mesh could reach it. An allowlist turns the
/// egress into a door for named peers only.
///
/// The check is on the connection's source address. That address is not
/// claimed by the peer: `FipsUdpSocket` builds it from the FIPS session's
/// authenticated `source_peer` (`AddrMap::insert`), and the IPv6 form is a hash
/// of that peer's public key, so a stranger cannot present an allowed one.
#[derive(Debug, Clone)]
pub struct Allowlist {
    ips: HashSet<Ipv6Addr>,
}

impl Allowlist {
    /// Build from bech32 npubs. Refuses an empty list (it would admit nobody,
    /// which is never what a caller meant) and any npub that does not decode.
    pub fn from_npubs<S: AsRef<str>>(npubs: &[S]) -> Result<Self> {
        if npubs.is_empty() {
            bail!("an egress allowlist needs at least one npub");
        }
        let mut ips = HashSet::new();
        for npub in npubs {
            let npub = npub.as_ref().trim();
            let pubkey = fips_endpoint::decode_npub(npub)
                .with_context(|| format!("allowlist entry is not an npub: {npub}"))?;
            ips.insert(AddrMap::ipv6_of(&PeerIdentity::from_pubkey(pubkey)));
        }
        Ok(Self { ips })
    }

    /// Whether a connection from this (FIPS-derived) address may proceed.
    pub fn permits(&self, addr: &SocketAddr) -> bool {
        match addr.ip() {
            IpAddr::V6(v6) => self.ips.contains(&v6),
            IpAddr::V4(_) => false,
        }
    }
}

/// Like [`serve`], but only for peers on `allow`. Everyone else is refused
/// before the QUIC handshake, so a stranger never gets a stream, let alone a
/// TCP connection to `target`.
pub async fn serve_allowlisted(
    quic: Arc<FipsQuic>,
    target: SocketAddr,
    allow: Allowlist,
) -> Result<()> {
    while let Some(incoming) = quic.endpoint.accept().await {
        let from = incoming.remote_address();
        if !allow.permits(&from) {
            tracing::warn!("egress refused a peer not on the allowlist: {from}");
            incoming.refuse();
            continue;
        }
        tokio::spawn(async move {
            match incoming.await {
                Ok(connection) => {
                    if let Err(e) = handle_connection(connection, target).await {
                        tracing::debug!("egress connection ended: {e}");
                    }
                }
                Err(e) => tracing::debug!("egress accept failed: {e}"),
            }
        });
    }
    Ok(())
}

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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::EndpointOptions;

    fn npub_of(nsec: &str) -> String {
        let secret = fips_endpoint::decode_nsec(nsec).unwrap();
        let identity = fips_endpoint::Identity::from_secret_key(secret);
        fips_endpoint::encode_npub(&identity.pubkey())
    }

    fn addr_of(npub: &str) -> SocketAddr {
        AddrMap::socket_addr_of(&PeerIdentity::from_pubkey(
            fips_endpoint::decode_npub(npub).unwrap(),
        ))
    }

    #[test]
    fn admits_listed_npubs_and_refuses_strangers() {
        let zap_box = npub_of(&EndpointOptions::generate_nsec());
        let other = npub_of(&EndpointOptions::generate_nsec());
        let stranger = npub_of(&EndpointOptions::generate_nsec());
        let allow = Allowlist::from_npubs(&[zap_box.as_str(), other.as_str()]).unwrap();

        assert!(allow.permits(&addr_of(&zap_box)));
        assert!(allow.permits(&addr_of(&other)));
        assert!(!allow.permits(&addr_of(&stranger)));
    }

    #[test]
    fn refuses_ipv4_and_unrelated_ipv6() {
        let zap_box = npub_of(&EndpointOptions::generate_nsec());
        let allow = Allowlist::from_npubs(&[zap_box]).unwrap();
        assert!(!allow.permits(&"127.0.0.1:4433".parse().unwrap()));
        assert!(!allow.permits(&"[fd00::1]:4433".parse().unwrap()));
    }

    #[test]
    fn rejects_empty_and_malformed_lists() {
        assert!(Allowlist::from_npubs::<&str>(&[]).is_err());
        assert!(Allowlist::from_npubs(&["not-an-npub"]).is_err());
        let nsec = EndpointOptions::generate_nsec();
        assert!(
            Allowlist::from_npubs(&[nsec.as_str()]).is_err(),
            "an nsec is not an npub"
        );
    }
}
