//! Phase 0a datagram probe.
//!
//! Answers the one question the whole FIPS architecture rests on: how large a
//! service datagram can we push through `fips-endpoint`, and where does the
//! behaviour change?
//!
//! Two numbers matter and they are NOT the same:
//!
//!   1. The API ceiling — what `send_datagram` accepts before returning
//!      `ServiceDatagramTooLarge`. Source says 65,525 (u16::MAX - 6 - 4).
//!   2. The *useful* ceiling — the largest payload that crosses the wire in a
//!      single FIPS fragment. Anything above it is reassembled from N fragments
//!      with no per-fragment retransmit and a 2s TTL, so a single lost fragment
//!      discards the whole datagram. That degrades silently: flawless on a LAN,
//!      collapsing on cellular.
//!
//! QUIC needs >= 1200 bytes to be viable at all (RFC 9000 anti-amplification;
//! quinn's `min_mtu` will not go below it). So the gate for the whole plan is
//! whether number 2 clears 1200.
//!
//! This binary measures both, in-process. In-process cannot fragment, so it
//! establishes the API ceiling and validates our API usage end to end; the
//! single-fragment figure needs the two-host run (see `--help`).

use anyhow::{Context, Result};
use fips_endpoint::{FipsEndpoint, FipsEndpointServiceDatagram, Identity, PeerIdentity};
use std::time::Duration;

/// Service port both ends agree on. 256-258 are reserved by FIPS itself.
const SERVICE_PORT: u16 = 4000;

/// Sizes worth knowing about, in bytes. The cluster around 1200-1400 is the
/// decision zone: 1242 is the computed usable payload at the default 1280 UDP
/// MTU, and 1362 is what we get after raising the MTU to 1400 via `.config()`.
const LADDER: &[usize] = &[
    64,      // canary
    512,     //
    1_000,   //
    1_200,   // QUIC's floor — must pass
    1_242,   // computed usable at default 1280 MTU
    1_300,   //
    1_362,   // computed usable at 1400 MTU
    1_400,   //
    1_500,   // classic Ethernet MTU
    2_000,   // certainly fragmenting by here
    8_192,   //
    32_768,  //
    65_525,  // documented API ceiling
    65_526,  // expected to be rejected
];

#[tokio::main]
async fn main() -> Result<()> {
    println!("FIPS datagram probe — fips-endpoint 0.4.45\n");

    let id_a = Identity::generate();
    let id_b = Identity::generate();
    let npub_b = id_b.npub();

    println!("  A: {}", id_a.npub());
    println!("  B: {}\n", npub_b);

    let endpoint_a = bind("A", &id_a).await?;
    let endpoint_b = bind("B", &id_b).await?;

    let receiver = endpoint_b
        .register_service_receiver(SERVICE_PORT)
        .await
        .context("B: register_service_receiver")?;

    let peer_b = PeerIdentity::from_pubkey(id_b.pubkey());

    // Peering is not instantaneous. Send a small canary until one lands, so a
    // failure below is a size failure rather than a not-yet-connected failure.
    println!("waiting for A -> B peering (canary, 30s budget)...");
    let mut peered = false;
    for attempt in 0..60 {
        let _ = endpoint_a
            .send_datagram(peer_b.clone(), SERVICE_PORT, SERVICE_PORT, vec![0u8; 64])
            .await;
        if recv_one(&receiver, Duration::from_millis(500)).await.is_some() {
            println!("  peered after {} attempt(s)\n", attempt + 1);
            peered = true;
            break;
        }
    }
    if !peered {
        println!("\n  NOT PEERED — two in-process endpoints did not find each other.");
        println!("  This is a discovery/config problem, not a size result.");
        println!("  Next step: give both endpoints an explicit UDP peer via");
        println!("  FipsEndpointBuilder::config(Config) rather than relying on");
        println!("  local_rendezvous() same-host composition.");
        return Ok(());
    }

    // Drain anything the canary loop left queued so it can't be misread as a
    // successful delivery of the first ladder rung.
    while recv_one(&receiver, Duration::from_millis(50)).await.is_some() {}

    println!("{:>8}  {:>8}  {}", "size", "result", "note");
    println!("{:->8}  {:->8}  {:->40}", "", "", "");

    let mut largest_delivered = 0usize;
    let mut api_ceiling = 0usize;

    for &size in LADDER {
        let payload = vec![0xABu8; size];
        match endpoint_a
            .send_datagram(peer_b.clone(), SERVICE_PORT, SERVICE_PORT, payload)
            .await
        {
            Err(e) => {
                println!("{:>8}  {:>8}  send rejected: {}", size, "REJECT", e);
                continue;
            }
            Ok(()) => {
                api_ceiling = api_ceiling.max(size);
            }
        }

        // Larger payloads fragment and reassemble, so allow real time.
        match recv_one(&receiver, Duration::from_secs(3)).await {
            Some(d) => {
                let got = d.data.len();
                largest_delivered = largest_delivered.max(size);
                let note = if got == size {
                    String::new()
                } else {
                    format!("SIZE MISMATCH: got {} bytes", got)
                };
                println!("{:>8}  {:>8}  {}", size, "ok", note);
            }
            None => {
                println!("{:>8}  {:>8}  accepted by API but never arrived", size, "LOST");
            }
        }
    }

    println!("\n--- results ---");
    println!("  API accepted up to:      {} bytes", api_ceiling);
    println!("  Largest delivered:       {} bytes", largest_delivered);

    println!("\n--- verdict ---");
    if largest_delivered >= 1_200 {
        println!("  PASS: 1200-byte datagrams cross the endpoint API.");
        println!("  QUIC-over-FIPS remains viable on this axis.");
    } else {
        println!("  FAIL: could not deliver 1200 bytes.");
        println!("  quinn cannot run below its 1200-byte floor — fall back to");
        println!("  a framed protocol, or to the FIPS WebSocket transport.");
    }

    println!("\n  NOTE: this run was in-process, so nothing fragmented and");
    println!("  nothing was lost. It proves the API surface and the ceiling,");
    println!("  NOT the single-fragment limit. Re-run across two hosts on");
    println!("  different networks for the number that actually decides the");
    println!("  transport under real loss.");

    let _ = endpoint_a.shutdown().await;
    let _ = endpoint_b.shutdown().await;
    Ok(())
}

async fn bind(label: &str, identity: &Identity) -> Result<FipsEndpoint> {
    let nsec = fips_endpoint::encode_nsec(&identity.keypair().secret_key());
    let endpoint = FipsEndpoint::builder()
        .identity_nsec(nsec)
        // Same scope on both ends so they discover each other.
        .discovery_scope("haven-fips-probe")
        // Host-wide authenticated loopback composition — how two endpoints on
        // one machine are meant to find each other.
        .local_rendezvous()
        // No TUN, no DNS takeover. This is the whole reason we can embed at all.
        .without_system_tun()
        .bind()
        .await
        .with_context(|| format!("{label}: bind"))?;
    println!("  {label} bound at {}", endpoint.address());
    Ok(endpoint)
}

/// Wait up to `timeout` for a single datagram on this service receiver.
async fn recv_one(
    receiver: &fips_endpoint::FipsEndpointServiceReceiver,
    timeout: Duration,
) -> Option<FipsEndpointServiceDatagram> {
    let mut buf: Vec<FipsEndpointServiceDatagram> = Vec::with_capacity(4);
    match tokio::time::timeout(timeout, receiver.recv_batch_into(&mut buf, 4)).await {
        Ok(Some(_)) => buf.into_iter().next(),
        _ => None,
    }
}
