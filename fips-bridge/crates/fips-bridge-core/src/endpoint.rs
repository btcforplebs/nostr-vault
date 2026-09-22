//! The only place (besides `transport::udp_socket`) that touches
//! `fips-endpoint` directly.
//!
//! Deliberate: that crate published 45 times on the 0.4 line and replaced its
//! entire send/recv model at the 0.3→0.4 boundary. Confining it to two files is
//! what keeps a rename upstream from reaching the C ABI, let alone Swift.

use std::sync::Arc;

use anyhow::{Context, Result};
use fips_endpoint::{
    Config, ConnectPolicy, FipsEndpoint, Identity, NostrDiscoveryPolicy, PeerAddress, PeerConfig,
    TransportInstances, UdpConfig,
};

/// The FIPS public test mesh: publicly reachable transit nodes that accept
/// inbound peering from any npub.
///
/// Two NAT'd nodes cannot peer on their own — a NAT-traversal offer rides an
/// authenticated FIPS session and is not a Nostr event, so with no shared
/// reachable node the offer never crosses. This is the shared reachable node.
///
/// Taken from `jmcorgan/fips-initramfs` (`conf/fips.yaml.example`), which ships
/// them as its defaults for the same reason. Both entries carry the hostname
/// *and* the literal address: the name survives the node moving, the address
/// survives DNS being unavailable, and neither alone survives both. Lower
/// priority is tried first, so the name is preferred.
///
/// Measured 2026-09-08 from this laptop against our pinned 0.4.72 endpoint:
/// `test-us02` reached an authenticated session (srtt 47 ms, 68 KB inbound over
/// 76 s) while `test-us01` did not answer at all. That is exactly why there are
/// two — and why a node whose only seed has moved has no signal as to why.
///
/// (alias, npub, hostname:port, address:port)
pub const PUBLIC_MESH_SEEDS: &[(&str, &str, &str, &str)] = &[
    (
        "test-us01",
        "npub1qmc3cvfz0yu2hx96nq3gp55zdan2qclealn7xshgr448d3nh6lks7zel98",
        "test-us01.fips.network:2121",
        "217.77.8.91:2121",
    ),
    (
        "test-us02",
        "npub10yffd020a4ag8zcy75f9pruq3rnghvvhd5hphl9s62zgp35s560qrksp9u",
        "test-us02.fips.network:2121",
        "23.182.128.74:2121",
    ),
];

/// The alias for a seed's npub, if it is one of ours.
///
/// Lives here so the names in the UI and the addresses being dialled cannot
/// drift apart: there is one seed table, and this reads it.
pub fn seed_alias(npub: &str) -> Option<&'static str> {
    PUBLIC_MESH_SEEDS
        .iter()
        .find(|(_, seed, _, _)| *seed == npub)
        .map(|(alias, _, _, _)| *alias)
}

/// [`PUBLIC_MESH_SEEDS`] as auto-connect peers.
pub fn public_mesh_peers() -> Vec<PeerConfig> {
    PUBLIC_MESH_SEEDS
        .iter()
        .map(|(alias, npub, host, addr)| PeerConfig {
            npub: (*npub).to_string(),
            alias: Some((*alias).to_string()),
            addresses: vec![
                PeerAddress::with_priority("udp", *host, 10),
                PeerAddress::with_priority("udp", *addr, 20),
            ],
            connect_policy: ConnectPolicy::AutoConnect,
            ..PeerConfig::default()
        })
        .collect()
}

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
    /// Publicly reachable transit nodes dialled on startup.
    ///
    /// Empty is a working configuration and a limited one: the endpoint still
    /// binds, still advertises, and still reaches anything on the LAN or
    /// anything directly reachable — it just cannot cross two NATs, because
    /// there is nothing in the middle to carry the traversal offer.
    pub bootstrap_peers: Vec<PeerConfig>,
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
        Self::with_identity(Self::generate_nsec(), discovery_scope)
            .local_rendezvous(true)
            // The in-process probes pair two endpoints over loopback; dialling
            // public transit would add traffic none of them measure.
            .bootstrap_peers(Vec::new())
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
            bootstrap_peers: public_mesh_peers(),
        }
    }

    /// Generate a fresh nsec, for a caller that wants to persist it itself.
    pub fn generate_nsec() -> String {
        let identity = Identity::generate();
        fips_endpoint::encode_nsec(&identity.keypair().secret_key())
    }

    /// Enable host-wide loopback composition. See [`Self::with_identity`] for
    /// why this is not the default.
    pub fn local_rendezvous(mut self, enabled: bool) -> Self {
        self.local_rendezvous = enabled;
        self
    }

    /// Replace the transit nodes dialled on startup. Pass an empty vec to dial
    /// none — see [`Self::bootstrap_peers`] for what that costs.
    pub fn bootstrap_peers(mut self, peers: Vec<PeerConfig>) -> Self {
        self.bootstrap_peers = peers;
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
/// only discovery behaviour that changes is the one field.
///
/// It also fills in `peers`, which the shortcut leaves empty. Those are transit
/// nodes, not discovery: see [`EndpointOptions::bootstrap_peers`].
fn endpoint_config(options: &EndpointOptions) -> Config {
    let scope = options.discovery_scope.as_str();
    let mut config = Config::new();

    config.node.discovery.nostr.enabled = true;
    config.node.discovery.nostr.advertise = true;
    config.node.discovery.nostr.policy = NostrDiscoveryPolicy::Open;
    config.node.discovery.nostr.share_local_candidates = true;
    config.node.discovery.nostr.app = scope.to_string();
    config.node.discovery.lan.scope = Some(scope.to_string());
    config.node.discovery.local.enabled = options.local_rendezvous;
    config.peers = options.bootstrap_peers.clone();
    config.transports.udp = TransportInstances::Single(UdpConfig {
        bind_addr: Some("0.0.0.0:0".to_string()),
        advertise_on_nostr: Some(true),
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
    fn an_app_endpoint_dials_the_public_transit_seeds() {
        // Without these, two NAT'd nodes have nothing in the middle and the
        // traversal offer never crosses. The failure is silent: both ends bind,
        // both advertise, neither ever connects.
        let config = scoped(EndpointOptions::with_identity("nsec-placeholder", "vault-test"));

        assert_eq!(config.peers.len(), PUBLIC_MESH_SEEDS.len());
        assert!(config.peers.iter().all(|p| p.is_auto_connect()));
        assert_eq!(
            config.auto_connect_peers().count(),
            PUBLIC_MESH_SEEDS.len(),
            "a seed that is not auto-connect is never dialled"
        );
    }

    #[test]
    fn the_hostname_is_tried_before_the_literal_address() {
        // Lowest priority first. The name survives the node moving and the
        // address survives DNS being unavailable; ordered the other way the
        // stale literal wins every boot where DNS works.
        for peer in public_mesh_peers() {
            let ordered = peer.addresses_by_priority();
            assert_eq!(ordered.len(), 2, "{:?} lost an address", peer.alias);
            assert!(
                ordered[0].addr.contains("fips.network"),
                "expected the hostname first, got {}",
                ordered[0].addr
            );
            assert!(
                ordered[1].addr.split(':').next().unwrap().parse::<std::net::IpAddr>().is_ok(),
                "expected a literal address second, got {}",
                ordered[1].addr
            );
        }
    }

    #[test]
    fn every_seed_npub_is_well_formed() {
        // A hard-coded key with a typo in it does not fail loudly; it is a peer
        // that never connects, which reads exactly like a seed being down.
        for (alias, npub, host, addr) in PUBLIC_MESH_SEEDS {
            assert!(fips_endpoint::decode_npub(npub).is_ok(), "{alias}: bad npub");
            assert!(host.ends_with(":2121"), "{alias}: {host} has no port");
            assert!(addr.ends_with(":2121"), "{alias}: {addr} has no port");
        }
    }

    #[test]
    fn a_seed_is_named_by_the_same_table_that_dials_it() {
        for (alias, npub, _, _) in PUBLIC_MESH_SEEDS {
            assert_eq!(seed_alias(npub), Some(*alias));
        }
        assert_eq!(seed_alias("npub1someoneelse"), None);
    }

    #[test]
    fn the_in_process_probes_dial_nothing_public() {
        // ephemeral() pairs two endpoints inside one process over loopback.
        // Public transit would add traffic none of those probes measure.
        let config = scoped(EndpointOptions::ephemeral("vault-test"));
        assert!(config.peers.is_empty());
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
