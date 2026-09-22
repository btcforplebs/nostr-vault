//! Mac-side provider for the two-host test.
//!
//! Serves a known blob over the FIPS mesh and prints the npub the consumer needs.
//! Pair this with the iOS probe app (or another machine) to get the measurement
//! that in-process testing structurally cannot produce: real RTT, real NAT
//! traversal, real packet loss, and — the number that actually decides the
//! transport — whether datagrams survive unfragmented on a real path.
//!
//! Usage:  cargo run --release --bin fips_serve
//!         FIPS_BLOB_MIB=20 cargo run --release --bin fips_serve

use std::sync::Arc;

use anyhow::Result;
use fips_bridge_core::proxy::egress;
use fips_bridge_core::{bind_endpoint, EndpointOptions, FipsQuic};
use fips_bridge_probe::{build_payload, origin_server, sha256};
use tokio::net::TcpListener;

const SCOPE: &str = "nostr-vault-fips";

#[tokio::main]
async fn main() -> Result<()> {
    let mib: usize = std::env::var("FIPS_BLOB_MIB")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(8);
    let blob = Arc::new(build_payload(mib * 1024 * 1024));
    let digest = sha256(&blob);

    let origin = TcpListener::bind("127.0.0.1:0").await?;
    let origin_addr = origin.local_addr()?;
    {
        let blob = blob.clone();
        tokio::spawn(async move { origin_server(origin, blob).await });
    }

    let endpoint = bind_endpoint(EndpointOptions::ephemeral(SCOPE)).await?;
    let npub = endpoint.npub().to_string();
    let address = endpoint.address().to_ipv6().to_string();

    let quic = Arc::new(FipsQuic::new(endpoint).await?);
    {
        let quic = quic.clone();
        tokio::spawn(async move {
            let _ = egress::serve(quic, origin_addr).await;
        });
    }

    println!("\n=========================================================");
    println!(" FIPS provider ready");
    println!("=========================================================");
    println!(" npub    : {npub}");
    println!(" address : {address}");
    println!(" blob    : {} MiB", mib);
    println!(" sha256  : {digest}");
    println!("---------------------------------------------------------");
    println!(" Paste the npub into the iOS probe app, or run the");
    println!(" consumer on another machine. Serving until interrupted.");
    println!("=========================================================\n");

    // Serve until killed.
    std::future::pending::<()>().await;
    Ok(())
}
