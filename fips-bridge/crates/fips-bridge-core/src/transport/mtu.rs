//! What actually fits in one FIPS datagram.
//!
//! This module exists because docs/fips/FIPS_INTEGRATION_ROADMAP.md §2.2 got the number
//! wrong, in the direction that hides the problem. It budgeted:
//!
//! ```text
//! 1280 - 12 (FSP outer) - 16 (AEAD tag) - 6 (inner hdr) - 4 (port hdr) = 1242
//! ```
//!
//! That counts the FSP layer and stops. The real send path wraps FSP inside FMP,
//! and fips-core states the total itself (`upper/icmp.rs:60-91`,
//! `FIPS_OVERHEAD = 106`):
//!
//! ```text
//! FMP outer header (cleartext AAD)                     16
//!   common prefix (4) + receiver_idx (4) + counter (8)
//! FMP AEAD ciphertext:
//!   timestamp (4) + msg_type (1)                        5   [FMP inner header]
//!   ttl (1) + path_mtu (2) + src (16) + dst (16)       35   [SessionDatagram body]
//!   FSP header (4 prefix + 8 counter)                  12   [cleartext AAD]
//!   FSP AEAD ciphertext:
//!     timestamp (4) + msg_type (1) + flags (1)          6   [FSP inner header]
//!     <application data>
//!     Poly1305 tag                                     16   [FSP AEAD]
//!   Poly1305 tag                                       16   [FMP AEAD]
//!                                                     ───
//!                                                     106
//! ```
//!
//! Service datagrams add `FSP_PORT_HEADER_SIZE` (4) for the source/destination
//! ports, so the figure that matters here is **110**. The roadmap omitted the
//! four FMP-layer items — 16 + 5 + 35 + 16 = 72 bytes — which is exactly the
//! 1242 - 1170 discrepancy.
//!
//! The consequence is not academic. quinn's `min_mtu` floor is 1200 (RFC 9000
//! anti-amplification; quinn will not go below it). At nostr-vpn's NAT-safe
//! default underlay MTU of 1280 we have 1170 usable, so **every QUIC packet is
//! already fragmenting into two FIPS fragments**. Reassembly is all-or-nothing
//! with no per-fragment retransmit, so link loss is roughly doubled by the time
//! quinn sees it.
//!
//! Cross-check against nostr-vpn, which derives the same numbers independently:
//! 1280 - 106 = 1174, minus a 24-byte cushion for the COORDS warmup tag = 1150,
//! which is their `MESH_TUNNEL_MTU` exactly.

/// Total FIPS encapsulation overhead for a service datagram, in bytes.
///
/// `FIPS_OVERHEAD` (106, fips-core `upper/icmp.rs:91`) plus
/// `FSP_PORT_HEADER_SIZE` (4, fips-core `proto/fsp_wire.rs`).
pub const SERVICE_DATAGRAM_OVERHEAD: usize = 110;

/// nostr-vpn's default underlay UDP MTU, and fips-core's `DEFAULT_UDP_MTU`.
///
/// Held at the IPv6-safe minimum deliberately. nostr-vpn raised it twice and
/// reverted twice: `Node::adopt_established_traversal` builds NAT-adopted UDP
/// transports from `UdpConfig::default()` at 1280, so any session promoted onto
/// a traversed link silently drops oversize datagrams at the socket layer.
pub const DEFAULT_UNDERLAY_UDP_MTU: u16 = 1280;

/// nostr-vpn's `lan` profile underlay MTU. Clean direct paths only.
pub const LAN_UNDERLAY_UDP_MTU: u16 = 1452;

/// quinn's hard floor. `min_mtu` will not go below this.
pub const QUIC_MIN_MTU: u16 = 1200;

/// Largest application payload that still fits in a single FIPS fragment.
pub const fn single_fragment_budget(underlay_udp_mtu: u16) -> usize {
    (underlay_udp_mtu as usize).saturating_sub(SERVICE_DATAGRAM_OVERHEAD)
}

/// How many FIPS fragments a service datagram of `payload_len` becomes.
///
/// Mirrors fips-core `dataplane/direct_transport.rs:381-392`: no fragmentation
/// while the *wire* length fits `path_mtu`, otherwise ceil-divide the wire
/// length by the per-fragment budget, which loses a further 20-byte fragment
/// header (`DIRECT_FSP_TRANSPORT_FRAGMENT_HEADER_LEN`).
pub const fn fragments_for(payload_len: usize, underlay_udp_mtu: u16) -> usize {
    let wire = payload_len + SERVICE_DATAGRAM_OVERHEAD;
    let mtu = underlay_udp_mtu as usize;
    if wire <= mtu {
        return 1;
    }
    let per_fragment = mtu.saturating_sub(20);
    if per_fragment == 0 {
        return usize::MAX;
    }
    wire.div_ceil(per_fragment)
}

/// Whether QUIC can run unfragmented at this underlay MTU.
///
/// False at the default 1280, which is the finding this module records.
pub const fn quic_fits_single_fragment(underlay_udp_mtu: u16) -> bool {
    single_fragment_budget(underlay_udp_mtu) >= QUIC_MIN_MTU as usize
}

/// Smallest underlay MTU at which a floor-sized QUIC packet is one fragment.
pub const fn min_underlay_for_unfragmented_quic() -> u16 {
    QUIC_MIN_MTU + SERVICE_DATAGRAM_OVERHEAD as u16
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_mtu_cannot_carry_a_floor_sized_quic_packet() {
        // The whole reason this module exists. If this ever starts passing,
        // either fips-core shrank its framing or someone raised the MTU —
        // either way §2.2 needs rereading before the assertion is deleted.
        assert_eq!(single_fragment_budget(DEFAULT_UNDERLAY_UDP_MTU), 1170);
        assert!(!quic_fits_single_fragment(DEFAULT_UNDERLAY_UDP_MTU));
        assert_eq!(min_underlay_for_unfragmented_quic(), 1310);
    }

    #[test]
    fn lan_profile_has_room() {
        assert_eq!(single_fragment_budget(LAN_UNDERLAY_UDP_MTU), 1342);
        assert!(quic_fits_single_fragment(LAN_UNDERLAY_UDP_MTU));
    }

    #[test]
    fn a_floor_sized_quic_packet_costs_two_fragments_at_the_default() {
        assert_eq!(fragments_for(1200, DEFAULT_UNDERLAY_UDP_MTU), 2);
        assert_eq!(fragments_for(1170, DEFAULT_UNDERLAY_UDP_MTU), 1);
        assert_eq!(fragments_for(1171, DEFAULT_UNDERLAY_UDP_MTU), 2);
        assert_eq!(fragments_for(1200, LAN_UNDERLAY_UDP_MTU), 1);
    }

    #[test]
    fn nostr_vpn_tunnel_mtu_is_reproduced() {
        // Their MESH_TUNNEL_MTU is 1150: 1280 - 106 FIPS_OVERHEAD - 24 cushion
        // for the COORDS warmup tag. Reproducing it is what tells us the 106 is
        // being read correctly rather than coincidentally.
        let without_port_header = DEFAULT_UNDERLAY_UDP_MTU as usize - 106;
        assert_eq!(without_port_header, 1174);
        assert_eq!(without_port_header - 24, 1150);
    }
}
