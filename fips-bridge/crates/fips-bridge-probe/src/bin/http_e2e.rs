//! Phase 0a: the whole product mechanism, without any app code.
//!
//! Stands up a real HTTP origin on loopback (standing in for the embedded Go
//! relay + Blossom server, which share one port), exports it over the FIPS mesh,
//! and re-exposes it on a *different* loopback port on the consumer side.
//!
//! If `curl http://127.0.0.1:<ingress>/blob` returns the right bytes, then so
//! will `AsyncImage`, `AVURLAsset`, Coil, ExoPlayer and every `URLSession` —
//! because none of them can tell the difference. That is the entire argument for
//! the loopback-proxy design over a `URLProtocol` shim.
//!
//! Deliberately exercises the three behaviours that would expose a proxy that
//! secretly parses HTTP: a full-body GET, a byte-range request (`206` +
//! `Content-Range`), and a `101 Switching Protocols` upgrade with traffic after
//! it — that last one being the relay's WSS path.
//!
//! Run with `HOLD=30` to keep the tunnel open for external curl testing.

use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use fips_bridge_core::proxy::{egress, Ingress};
use fips_bridge_core::{bind_endpoint, EndpointOptions, FipsQuic};
use fips_endpoint::PeerIdentity;
use sha2::{Digest, Sha256};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

const SCOPE: &str = "haven-fips-http";
const BLOB_BYTES: usize = 4 * 1024 * 1024;

#[tokio::main]
async fn main() -> Result<()> {
    println!("HTTP-over-FIPS end-to-end\n");

    let blob = Arc::new(build_payload(BLOB_BYTES));
    let blob_digest = sha256(&blob);
    println!("  blob: {} bytes, sha256 {}", blob.len(), blob_digest);

    // The "provider": an ordinary HTTP origin, as the Go relay would be.
    let origin = TcpListener::bind("127.0.0.1:0").await?;
    let origin_addr = origin.local_addr()?;
    println!("  origin listening on {origin_addr}");
    {
        let blob = blob.clone();
        tokio::spawn(async move { origin_server(origin, blob).await });
    }

    // Two endpoints, as if two devices.
    let fips_provider = bind_endpoint(EndpointOptions::ephemeral(SCOPE)).await?;
    let fips_consumer = bind_endpoint(EndpointOptions::ephemeral(SCOPE)).await?;
    let provider_npub = fips_provider.npub().to_string();
    println!("  provider: {provider_npub}");

    let provider_quic = Arc::new(FipsQuic::new(fips_provider).await?);
    let consumer_quic = Arc::new(FipsQuic::new(fips_consumer).await?);

    // Provider exports its local origin to the mesh.
    {
        let quic = provider_quic.clone();
        tokio::spawn(async move { egress::serve(quic, origin_addr).await });
    }

    // Consumer re-exposes it on its own loopback port.
    let peer = PeerIdentity::from_pubkey(
        fips_endpoint::decode_npub(&provider_npub).context("decode provider npub")?,
    );
    // Fixed port when asked, so an external client (curl) can find it.
    let ingress_bind = std::env::var("INGRESS_PORT")
        .ok()
        .and_then(|p| p.parse::<u16>().ok())
        .map(|p| format!("127.0.0.1:{p}"))
        .unwrap_or_else(|| "127.0.0.1:0".to_string());
    let ingress_listener = TcpListener::bind(&ingress_bind).await?;
    let ingress_addr = ingress_listener.local_addr()?;
    let ingress = Ingress::new(consumer_quic.clone(), peer);
    {
        let ingress = ingress.clone();
        tokio::spawn(async move { ingress.serve(ingress_listener).await });
    }

    println!("\n  consumer loopback origin: http://127.0.0.1:{}\n", ingress_addr.port());
    // Let FIPS peering settle before the first request.
    tokio::time::sleep(Duration::from_millis(500)).await;

    let mut failures = Vec::new();

    // 1. Full GET.
    let started = Instant::now();
    let (status, headers, body) = http_get(ingress_addr, "/blob", &[]).await?;
    let elapsed = started.elapsed();
    let got = sha256(&body);
    println!("[1] full GET");
    println!("    status  : {status}");
    println!("    bytes   : {} (expected {})", body.len(), blob.len());
    println!("    sha256  : {got}");
    println!(
        "    elapsed : {:.2}s ({:.1} MiB/s)",
        elapsed.as_secs_f64(),
        (body.len() as f64 / 1024.0 / 1024.0) / elapsed.as_secs_f64()
    );
    if status != 200 || got != blob_digest {
        failures.push("full GET");
    }

    // 2. Range request — proves byte-transparency, not HTTP re-serialization.
    let (status, headers_r, body_r) =
        http_get(ingress_addr, "/blob", &[("Range", "bytes=0-1023")]).await?;
    let has_content_range = headers_r.to_lowercase().contains("content-range:");
    println!("\n[2] range GET (bytes=0-1023)");
    println!("    status        : {status}");
    println!("    bytes         : {}", body_r.len());
    println!("    content-range : {has_content_range}");
    if status != 206 || body_r.len() != 1024 || !has_content_range || body_r[..] != blob[..1024] {
        failures.push("range GET");
    }

    // 3. Upgrade — the relay's WSS path.
    let (status, _, echoed) = http_upgrade(ingress_addr).await?;
    println!("\n[3] 101 upgrade + post-upgrade traffic");
    println!("    status : {status}");
    println!("    echoed : {:?}", String::from_utf8_lossy(&echoed));
    if status != 101 || echoed != b"PING-OVER-MESH" {
        failures.push("upgrade");
    }

    let _ = headers;

    println!("\n--- verdict ---");
    if failures.is_empty() {
        println!("  PASS: a real HTTP origin is reachable over the mesh through a");
        println!("  loopback port, with ranges and upgrades intact.");
        println!("  Blossom media and relay WSS are the same pipe — as designed.");
    } else {
        println!("  FAIL: {failures:?}");
    }

    if let Ok(secs) = std::env::var("HOLD") {
        let secs: u64 = secs.parse().unwrap_or(30);
        println!("\n  holding {secs}s — try:");
        println!("    curl -s http://127.0.0.1:{}/blob | shasum -a 256", ingress_addr.port());
        tokio::time::sleep(Duration::from_secs(secs)).await;
    }

    if !failures.is_empty() {
        bail!("{} check(s) failed", failures.len());
    }
    Ok(())
}

/// A deliberately plain HTTP/1.1 origin. Stands in for the Go relay; the point
/// is that the proxy never learns anything about it.
async fn origin_server(listener: TcpListener, blob: Arc<Vec<u8>>) {
    loop {
        let Ok((mut stream, _)) = listener.accept().await else {
            return;
        };
        let blob = blob.clone();
        tokio::spawn(async move {
            let mut buf = Vec::new();
            let mut chunk = [0u8; 4096];
            // Read just the request head.
            loop {
                let Ok(n) = stream.read(&mut chunk).await else {
                    return;
                };
                if n == 0 {
                    return;
                }
                buf.extend_from_slice(&chunk[..n]);
                if buf.windows(4).any(|w| w == b"\r\n\r\n") {
                    break;
                }
            }
            let head = String::from_utf8_lossy(&buf).to_string();
            let lower = head.to_lowercase();

            if lower.contains("upgrade: websocket") {
                let _ = stream
                    .write_all(
                        b"HTTP/1.1 101 Switching Protocols\r\n\
                          Upgrade: websocket\r\nConnection: Upgrade\r\n\r\n",
                    )
                    .await;
                // Echo whatever arrives next, proving the tunnel stays open
                // bidirectionally after the upgrade.
                let mut post = [0u8; 256];
                if let Ok(n) = stream.read(&mut post).await {
                    let _ = stream.write_all(&post[..n]).await;
                }
                let _ = stream.flush().await;
                return;
            }

            // Byte range?
            if let Some(range) = lower.split("range: bytes=").nth(1) {
                let spec = range.split("\r\n").next().unwrap_or("");
                let mut parts = spec.split('-');
                let start: usize = parts.next().unwrap_or("0").trim().parse().unwrap_or(0);
                let end: usize = parts
                    .next()
                    .unwrap_or("")
                    .trim()
                    .parse()
                    .unwrap_or(blob.len().saturating_sub(1));
                let end = end.min(blob.len().saturating_sub(1));
                let slice = &blob[start..=end];
                let header = format!(
                    "HTTP/1.1 206 Partial Content\r\nContent-Type: application/octet-stream\r\n\
                     Content-Range: bytes {}-{}/{}\r\nContent-Length: {}\r\n\
                     Accept-Ranges: bytes\r\nConnection: close\r\n\r\n",
                    start,
                    end,
                    blob.len(),
                    slice.len()
                );
                let _ = stream.write_all(header.as_bytes()).await;
                let _ = stream.write_all(slice).await;
                let _ = stream.flush().await;
                return;
            }

            let header = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n\
                 Content-Length: {}\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n",
                blob.len()
            );
            let _ = stream.write_all(header.as_bytes()).await;
            let _ = stream.write_all(&blob).await;
            let _ = stream.flush().await;
        });
    }
}

async fn http_get(
    addr: std::net::SocketAddr,
    path: &str,
    extra: &[(&str, &str)],
) -> Result<(u16, String, Vec<u8>)> {
    let mut stream = TcpStream::connect(addr).await?;
    let mut request = format!("GET {path} HTTP/1.1\r\nHost: fips.local\r\n");
    for (k, v) in extra {
        request.push_str(&format!("{k}: {v}\r\n"));
    }
    request.push_str("Connection: close\r\n\r\n");
    stream.write_all(request.as_bytes()).await?;

    let mut raw = Vec::new();
    stream.read_to_end(&mut raw).await?;
    split_response(&raw)
}

async fn http_upgrade(addr: std::net::SocketAddr) -> Result<(u16, String, Vec<u8>)> {
    let mut stream = TcpStream::connect(addr).await?;
    stream
        .write_all(
            b"GET /ws HTTP/1.1\r\nHost: fips.local\r\n\
              Upgrade: websocket\r\nConnection: Upgrade\r\n\r\n",
        )
        .await?;

    // Read the response head, then send traffic *after* the upgrade.
    let mut head = Vec::new();
    let mut byte = [0u8; 1];
    while !head.windows(4).any(|w| w == b"\r\n\r\n") {
        let n = stream.read(&mut byte).await?;
        if n == 0 {
            break;
        }
        head.push(byte[0]);
    }
    stream.write_all(b"PING-OVER-MESH").await?;

    let mut echoed = Vec::new();
    let mut chunk = [0u8; 256];
    let n = stream.read(&mut chunk).await.unwrap_or(0);
    echoed.extend_from_slice(&chunk[..n]);

    let text = String::from_utf8_lossy(&head).to_string();
    let status = parse_status(&text);
    Ok((status, text, echoed))
}

fn split_response(raw: &[u8]) -> Result<(u16, String, Vec<u8>)> {
    let split = raw
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .context("no header terminator in response")?;
    let head = String::from_utf8_lossy(&raw[..split]).to_string();
    let body = raw[split + 4..].to_vec();
    let status = parse_status(&head);
    Ok((status, head, body))
}

fn parse_status(head: &str) -> u16 {
    head.lines()
        .next()
        .and_then(|l| l.split_whitespace().nth(1))
        .and_then(|c| c.parse().ok())
        .unwrap_or(0)
}

fn build_payload(len: usize) -> Vec<u8> {
    let mut out = Vec::with_capacity(len);
    let mut state: u32 = 0x9E3779B9;
    while out.len() < len {
        state = state.wrapping_mul(1664525).wrapping_add(1013904223);
        out.extend_from_slice(&state.to_le_bytes());
    }
    out.truncate(len);
    out
}

fn sha256(data: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(data);
    hasher.finalize().iter().map(|b| format!("{b:02x}")).collect()
}
