//! The egress allowlist end to end: two real FIPS endpoints paired over
//! host-wide loopback rendezvous, with Nostr discovery off so nothing is
//! published. The allowlisted consumer reaches the origin; a stranger on the
//! same mesh does not.

use std::sync::Arc;
use std::time::Duration;

use fips_bridge_core::proxy::egress::{self, Allowlist};
use fips_bridge_core::proxy::Ingress;
use fips_bridge_core::{bind_endpoint, EndpointOptions, FipsQuic};
use fips_endpoint::PeerIdentity;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

fn options(scope: &str) -> EndpointOptions {
    EndpointOptions::ephemeral(scope).nostr_discovery(false)
}

/// Writes a line through the consumer's loopback port and waits for the
/// origin's reply. `None` if the tunnel never carries it.
async fn round_trip(port: u16) -> Option<String> {
    let attempt = async {
        let mut tcp = TcpStream::connect(("127.0.0.1", port)).await.ok()?;
        tcp.write_all(b"ping\n").await.ok()?;
        tcp.shutdown().await.ok()?;
        let mut out = String::new();
        tcp.read_to_string(&mut out).await.ok()?;
        (!out.is_empty()).then_some(out)
    };
    tokio::time::timeout(Duration::from_secs(8), attempt)
        .await
        .ok()
        .flatten()
}

async fn consumer_port(scope: &str, provider: PeerIdentity) -> (String, u16) {
    let endpoint = bind_endpoint(options(scope)).await.unwrap();
    let npub = endpoint.npub().to_string();
    let quic = Arc::new(FipsQuic::new(endpoint).await.unwrap());
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let ingress = Ingress::new(quic, provider);
    tokio::spawn(async move { ingress.serve(listener).await });
    (npub, port)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn allowlisted_peer_gets_through_and_a_stranger_does_not() {
    let scope = format!("egress-allowlist-test-{}", std::process::id());

    // The origin: replies "pong" to anything.
    let origin = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let origin_addr = origin.local_addr().unwrap();
    tokio::spawn(async move {
        while let Ok((mut tcp, _)) = origin.accept().await {
            tokio::spawn(async move {
                let mut buf = Vec::new();
                let _ = tcp.read_to_end(&mut buf).await;
                let _ = tcp.write_all(b"pong\n").await;
            });
        }
    });

    let provider = bind_endpoint(options(&scope)).await.unwrap();
    let provider_peer =
        PeerIdentity::from_pubkey(fips_endpoint::decode_npub(provider.npub()).unwrap());
    let provider_quic = Arc::new(FipsQuic::new(provider).await.unwrap());

    let (allowed_npub, allowed_port) = consumer_port(&scope, provider_peer).await;
    let (_stranger_npub, stranger_port) = consumer_port(&scope, provider_peer).await;

    let allow = Allowlist::from_npubs(&[allowed_npub]).unwrap();
    tokio::spawn(async move { egress::serve_allowlisted(provider_quic, origin_addr, allow).await });
    tokio::time::sleep(Duration::from_millis(800)).await;

    // The allowlisted consumer may need a moment while peering settles.
    let mut allowed = None;
    for _ in 0..5 {
        allowed = round_trip(allowed_port).await;
        if allowed.is_some() {
            break;
        }
    }
    assert_eq!(
        allowed.as_deref(),
        Some("pong\n"),
        "the allowlisted npub must reach the origin"
    );

    assert_eq!(
        round_trip(stranger_port).await,
        None,
        "a stranger must never reach the origin"
    );
}
