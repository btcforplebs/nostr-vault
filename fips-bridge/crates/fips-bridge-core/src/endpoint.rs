//! The only place (besides `transport::udp_socket`) that touches
//! `fips-endpoint` directly.
//!
//! Deliberate: that crate published 45 times on the 0.4 line and replaced its
//! entire send/recv model at the 0.3→0.4 boundary. Confining it to two files is
//! what keeps a rename upstream from reaching the C ABI, let alone Swift.

use std::sync::Arc;

use anyhow::{Context, Result};
use fips_endpoint::{FipsEndpoint, Identity};

#[derive(Debug, Clone)]
pub struct EndpointOptions {
    /// nsec (bech32) or hex secret. Distinct from the user's Nostr identity —
    /// network identity should be rotatable without touching the social one.
    pub nsec: String,
    /// Application-level discovery scope. Both ends must agree.
    pub discovery_scope: String,
    /// Enable host-wide authenticated loopback composition. Useful for tests
    /// and for composing with another FIPS instance on the same machine.
    pub local_rendezvous: bool,
}

impl EndpointOptions {
    /// A throwaway identity, for tests and probes.
    pub fn ephemeral(discovery_scope: impl Into<String>) -> Self {
        let identity = Identity::generate();
        Self {
            nsec: fips_endpoint::encode_nsec(&identity.keypair().secret_key()),
            discovery_scope: discovery_scope.into(),
            local_rendezvous: true,
        }
    }
}

/// Bind an embedded FIPS endpoint.
///
/// `without_system_tun()` is the load-bearing call: it is what makes this
/// embeddable in a sandboxed Mac app and an App Store iOS app at all, with no
/// TUN device, no DNS takeover, and no NetworkExtension entitlement.
pub async fn bind_endpoint(options: EndpointOptions) -> Result<Arc<FipsEndpoint>> {
    let mut builder = FipsEndpoint::builder()
        .identity_nsec(options.nsec)
        .discovery_scope(options.discovery_scope)
        .without_system_tun();

    if options.local_rendezvous {
        builder = builder.local_rendezvous();
    }

    let endpoint = builder.bind().await.context("bind FIPS endpoint")?;
    Ok(Arc::new(endpoint))
}
