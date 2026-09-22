//! Bidirectional map between the `SocketAddr`s quinn insists on and the
//! `PeerIdentity`s FIPS routes by.
//!
//! FIPS addresses are already IPv6-shaped (`fd00::/8` ULA, 120 bits of
//! node_addr hash), so this is a near-free translation rather than a synthetic
//! addressing scheme: every peer has exactly one stable IPv6 form.

use std::collections::HashMap;
use std::net::{IpAddr, Ipv6Addr, SocketAddr};
use std::sync::RwLock;

use fips_endpoint::{FipsAddress, PeerIdentity};

/// The port component of every synthesized `SocketAddr`. QUIC needs a port to
/// exist; FIPS routes by identity plus service port, so this is cosmetic and
/// only has to be consistent.
pub const QUIC_ADDR_PORT: u16 = 4433;

#[derive(Debug, Default)]
pub struct AddrMap {
    by_ip: RwLock<HashMap<Ipv6Addr, PeerIdentity>>,
}

impl AddrMap {
    pub fn new() -> Self {
        Self::default()
    }

    /// The IPv6 form of a peer. Deterministic, so both ends agree without
    /// having to exchange anything.
    pub fn ipv6_of(peer: &PeerIdentity) -> Ipv6Addr {
        FipsAddress::from_node_addr(peer.node_addr()).to_ipv6()
    }

    /// The `SocketAddr` quinn will use for this peer.
    pub fn socket_addr_of(peer: &PeerIdentity) -> SocketAddr {
        SocketAddr::new(IpAddr::V6(Self::ipv6_of(peer)), QUIC_ADDR_PORT)
    }

    /// Record a peer so inbound datagrams and outbound sends can be translated.
    /// Called on every send target and on every received datagram, so the map
    /// self-populates.
    pub fn insert(&self, peer: PeerIdentity) -> SocketAddr {
        let ip = Self::ipv6_of(&peer);
        self.by_ip.write().unwrap().insert(ip, peer);
        SocketAddr::new(IpAddr::V6(ip), QUIC_ADDR_PORT)
    }

    /// Resolve a quinn destination back to a FIPS peer.
    pub fn lookup(&self, addr: &SocketAddr) -> Option<PeerIdentity> {
        let ip = match addr.ip() {
            IpAddr::V6(v6) => v6,
            IpAddr::V4(_) => return None,
        };
        self.by_ip.read().unwrap().get(&ip).cloned()
    }
}
