//! The only place (besides `transport::udp_socket`) that touches
//! `fips-endpoint` directly.
//!
//! Deliberate: that crate published 45 times on the 0.4 line and replaced its
//! entire send/recv model at the 0.3→0.4 boundary. Confining it to two files is
//! what keeps a rename upstream from reaching the C ABI, let alone Swift.

use std::sync::Arc;

use anyhow::{Context, Result};
use fips_endpoint::{
    Config, FipsEndpoint, Identity, NostrDiscoveryPolicy, TransportInstances, UdpConfig,
};

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
    /// Advertise and look up peers on public Nostr relays. On by default; off
    /// for tests that must not publish anything and pair over local
    /// rendezvous alone.
    pub nostr_discovery: bool,
}

impl EndpointOptions {
    /// A throwaway identity, for tests and probes.
    ///
    /// A fresh identity every launch means a peer that knew this endpoint's
    /// npub cannot find it again after a restart, so this is deliberately not
    /// what the app uses -- see [`Self::with_identity`].
    pub fn ephemeral(discovery_scope: impl Into<String>) -> Self {
        // Same-host composition stays on here: the in-process e2e probes
        // pair two endpoints inside one process and rely on it.
        Self::with_identity(Self::generate_nsec(), discovery_scope).local_rendezvous(true)
    }

    /// A stable identity supplied by the caller.
    ///
    /// `local_rendezvous` is off here on purpose. It binds 127.0.0.1:21211
    /// exclusively, which collides with a co-installed nostr-vpn, and it is a
    /// same-host path: leaving it on during an off-LAN test would let a run
    /// pass for a reason the test is not measuring.
    pub fn with_identity(nsec: impl Into<String>, discovery_scope: impl Into<String>) -> Self {
        Self {
            nsec: nsec.into(),
            discovery_scope: discovery_scope.into(),
            local_rendezvous: false,
            nostr_discovery: true,
        }
    }

    /// Generate a fresh nsec, for a caller that wants to persist it itself.
    pub fn generate_nsec() -> String {
        let identity = Identity::generate();
        fips_endpoint::encode_nsec(&identity.keypair().secret_key())
    }

    /// Turn Nostr-relay discovery off (see the field).
    pub fn nostr_discovery(mut self, enabled: bool) -> Self {
        self.nostr_discovery = enabled;
        self
    }

    /// Enable host-wide loopback composition. See [`Self::with_identity`] for
    /// why this is not the default.
    pub fn local_rendezvous(mut self, enabled: bool) -> Self {
        self.local_rendezvous = enabled;
        self
    }
}

/// The endpoint config, built here rather than left to the builder's
/// `discovery_scope` shortcut.
///
/// That shortcut is why `local_rendezvous: false` did nothing. In
/// nvpn-fips-core 0.4.72, `apply_default_scoped_discovery` (endpoint.rs:185)
/// runs whenever no transport has been configured, and it sets
/// `node.discovery.local.enabled = true` unconditionally along with the Nostr
/// advert and the UDP transport. So every endpoint we bound joined host-wide
/// loopback rendezvous regardless of the flag, whatever the doc comment on
/// [`EndpointOptions::with_identity`] promised.
///
/// Supplying the config ourselves is what makes the flag real: the shortcut
/// returns early once `transports` is non-empty, leaving the explicit config in
/// control. The rest of this function reproduces that profile exactly, so the
/// only behaviour that changes is the one field.
fn endpoint_config(options: &EndpointOptions) -> Config {
    let scope = options.discovery_scope.as_str();
    let mut config = Config::new();

    config.node.discovery.nostr.enabled = options.nostr_discovery;
    config.node.discovery.nostr.advertise = options.nostr_discovery;
    config.node.discovery.nostr.policy = NostrDiscoveryPolicy::Open;
    config.node.discovery.nostr.share_local_candidates = true;
    config.node.discovery.nostr.app = scope.to_string();
    config.node.discovery.lan.scope = Some(scope.to_string());
    config.node.discovery.local.enabled = options.local_rendezvous;
    config.transports.udp = TransportInstances::Single(UdpConfig {
        bind_addr: Some("0.0.0.0:0".to_string()),
        advertise_on_nostr: Some(options.nostr_discovery),
        public: Some(false),
        outbound_only: Some(false),
        accept_connections: Some(true),
        ..UdpConfig::default()
    });

    config
}

/// Bind an embedded FIPS endpoint.
///
/// `without_system_tun()` is the load-bearing call: it is what makes this
/// embeddable in a sandboxed Mac app and an App Store iOS app at all, with no
/// TUN device, no DNS takeover, and no NetworkExtension entitlement.
pub async fn bind_endpoint(options: EndpointOptions) -> Result<Arc<FipsEndpoint>> {
    let config = endpoint_config(&options);
    let endpoint = FipsEndpoint::builder()
        .config(config)
        .identity_nsec(options.nsec)
        .discovery_scope(options.discovery_scope)
        .without_system_tun()
        .bind()
        .await
        .context("bind FIPS endpoint")?;
    Ok(Arc::new(endpoint))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scoped(options: EndpointOptions) -> Config {
        endpoint_config(&options)
    }

    #[test]
    fn with_identity_does_not_join_host_wide_rendezvous() {
        // The invariant with_identity's doc comment promises. It was false for
        // the whole life of that function: the builder shortcut turned local
        // discovery back on behind it, so an off-LAN run could still pair over
        // loopback and pass for a reason the test was not measuring.
        let config = scoped(EndpointOptions::with_identity("nsec-placeholder", "vault-test"));
        assert!(!config.node.discovery.local.enabled);
    }

    #[test]
    fn ephemeral_still_composes_on_one_host() {
        // The in-process e2e probes pair two endpoints inside one process and
        // depend on this staying on.
        let config = scoped(EndpointOptions::ephemeral("vault-test"));
        assert!(config.node.discovery.local.enabled);
    }

    #[test]
    fn the_flag_is_the_only_thing_that_moves() {
        let off = scoped(EndpointOptions::with_identity("nsec-placeholder", "vault-test"));
        let on = scoped(
            EndpointOptions::with_identity("nsec-placeholder", "vault-test")
                .local_rendezvous(true),
        );
        assert!(!off.node.discovery.local.enabled);
        assert!(on.node.discovery.local.enabled);

        // Nothing else may differ. Config has no PartialEq, and pulling in
        // serde_json only for a test would move the pinned lock, so compare
        // Debug output -- it walks every field either way.
        let mut normalised = off.clone();
        normalised.node.discovery.local.enabled = true;
        assert_eq!(format!("{normalised:?}"), format!("{on:?}"));
    }

    #[test]
    fn the_scoped_discovery_profile_is_reproduced() {
        // If this drifts from apply_default_scoped_discovery upstream, we are
        // no longer binding what the shortcut would have bound, and the reason
        // for taking the config into our own hands has quietly changed.
        let config = scoped(EndpointOptions::with_identity("nsec-placeholder", "vault-test"));
        assert!(config.node.discovery.nostr.enabled);
        assert!(config.node.discovery.nostr.advertise);
        assert!(config.node.discovery.nostr.share_local_candidates);
        assert_eq!(config.node.discovery.nostr.app, "vault-test");
        assert_eq!(config.node.discovery.lan.scope.as_deref(), Some("vault-test"));

        let TransportInstances::Single(udp) = &config.transports.udp else {
            panic!("expected exactly one UDP transport instance");
        };
        assert_eq!(udp.bind_addr.as_deref(), Some("0.0.0.0:0"));
        assert_eq!(udp.advertise_on_nostr, Some(true));
        assert_eq!(udp.public, Some(false));
        assert_eq!(udp.outbound_only, Some(false));
        assert_eq!(udp.accept_connections, Some(true));
    }
}
