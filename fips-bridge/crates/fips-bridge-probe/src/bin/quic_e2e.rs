//! Phase 0a step 4: prove QUIC runs over FIPS service datagrams, and that a
//! large blob survives the trip intact.
//!
//! This is the load-bearing test for the whole architecture. If QUIC cannot ride
//! on `fips-endpoint` datagrams, the loopback-proxy design collapses and the
//! fallback is a hand-rolled framed protocol (with all the congestion-control
//! risk that implies).
//!
//! What it does: stands up two embedded FIPS endpoints, runs a quinn server on
//! one and a client on the other, streams a blob across a bidirectional QUIC
//! stream, and verifies the sha256 end to end. Blobs are content-addressed in
//! Blossom, so a hash match is exactly the property that matters in production.
//!
//! Size override: `FIPS_E2E_BYTES=4194304 cargo run --release --bin quic_e2e`

use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use fips_bridge_core::{bind_endpoint, quinn, EndpointOptions, FipsQuic};
use fips_endpoint::PeerIdentity;
use sha2::{Digest, Sha256};

const DEFAULT_BYTES: usize = 20 * 1024 * 1024;
const SCOPE: &str = "haven-fips-e2e";

#[tokio::main]
async fn main() -> Result<()> {
    let total: usize = std::env::var("FIPS_E2E_BYTES")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(DEFAULT_BYTES);

    println!("QUIC-over-FIPS end-to-end — {} MiB\n", total / 1024 / 1024);

    // Two independent endpoints, as if they were two devices.
    let fips_server = bind_endpoint(EndpointOptions::ephemeral(SCOPE)).await?;
    let fips_client = bind_endpoint(EndpointOptions::ephemeral(SCOPE)).await?;

    let server_npub = fips_server.npub().to_string();
    println!("  server: {server_npub}");
    println!("  client: {}\n", fips_client.npub());

    let server = FipsQuic::new(fips_server.clone()).await?;
    let client = FipsQuic::new(fips_client.clone()).await?;

    let payload = build_payload(total);
    let expected = sha256(&payload);
    println!("  payload sha256: {expected}\n");

    // Server: accept one connection, read the stream to EOF, reply with the
    // digest it computed itself.
    let server_task = tokio::spawn(async move {
        let connection = match server.accept().await {
            Some(result) => result?,
            None => bail!("server endpoint closed before a connection arrived"),
        };
        let (mut send, mut recv) = connection
            .accept_bi()
            .await
            .context("server accept_bi")?;

        let received = recv
            .read_to_end(64 * 1024 * 1024)
            .await
            .context("server read_to_end")?;

        let digest = sha256(&received);
        send.write_all(digest.as_bytes()).await?;
        send.finish()?;
        // Give the final frames a moment to drain before the endpoint drops.
        tokio::time::sleep(Duration::from_millis(200)).await;
        Ok::<_, anyhow::Error>((received.len(), digest))
    });

    let peer = PeerIdentity::from_pubkey(
        fips_endpoint::decode_npub(&server_npub).context("decode server npub")?,
    );

    // FIPS peering settles within a datagram or two, but the QUIC handshake has
    // its own deadline — retry rather than racing it.
    println!("connecting over the mesh...");
    let connection = connect_with_retry(&client, peer, 5).await?;
    println!("  connected\n");

    let started = Instant::now();
    let (mut send, mut recv) = connection.open_bi().await.context("client open_bi")?;
    send.write_all(&payload).await.context("client write_all")?;
    send.finish().context("client finish")?;

    let echoed = recv
        .read_to_end(128)
        .await
        .context("client read digest")?;
    let elapsed = started.elapsed();

    let reported = String::from_utf8(echoed).context("digest not utf8")?;
    let (received_len, server_digest) = server_task.await??;

    let mib = total as f64 / 1024.0 / 1024.0;
    let secs = elapsed.as_secs_f64();

    println!("--- results ---");
    println!("  bytes sent:     {total}");
    println!("  bytes received: {received_len}");
    println!("  elapsed:        {:.2}s", secs);
    println!("  throughput:     {:.2} MiB/s", mib / secs);
    println!("  expected:       {expected}");
    println!("  server saw:     {server_digest}");
    println!("  reported back:  {reported}");

    println!("\n--- verdict ---");
    if reported == expected && server_digest == expected && received_len == total {
        println!("  PASS: QUIC runs over FIPS datagrams and the blob is byte-identical.");
        println!("  The loopback-proxy architecture is viable on this axis.");
    } else {
        println!("  FAIL: payload did not survive intact.");
        bail!("integrity check failed");
    }

    println!("\n  NOTE: in-process run — no fragmentation, no loss, no real RTT.");
    println!("  The throughput figure above is an upper bound, not a prediction.");
    println!("  Two hosts on different networks is what settles the transport.");

    Ok(())
}

async fn connect_with_retry(
    client: &FipsQuic,
    peer: PeerIdentity,
    attempts: usize,
) -> Result<quinn::Connection> {
    let mut last = None;
    for attempt in 1..=attempts {
        match client.connect(peer.clone()).await {
            Ok(connection) => return Ok(connection),
            Err(e) => {
                println!("  attempt {attempt}/{attempts} failed: {e}");
                last = Some(e);
                tokio::time::sleep(Duration::from_secs(1)).await;
            }
        }
    }
    Err(last.unwrap_or_else(|| anyhow::anyhow!("no connection attempts made")))
}

/// Non-repeating payload, so a truncation or a duplicated block cannot
/// accidentally produce a matching hash.
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
    hasher
        .finalize()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}
