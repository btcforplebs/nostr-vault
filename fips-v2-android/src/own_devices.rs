//! Own-devices mode, for a vault that serves only its owner's devices (the
//! Mac app, in place of the fipsv2-probe helper's `serve --peer`).
//!
//! With `own_devices` set at start:
//! - traversal offers are answered only from those npubs (`offer_allowlist`),
//!   so this node's public address goes to no one else;
//! - each one is dialed at start, as a configured peer;
//! - mesh packets from anyone else never reach their stack: they go to the
//!   strangers' stack ([`crate::strangers`]), which is capped, or are
//!   dropped when there is none;
//! - `ingress` dials own devices only, since a dial sends this node's address.
//! - own devices' sharing has no byte or connection caps: those are for
//!   strangers, in their own stack.

use std::collections::HashSet;
use std::net::Ipv6Addr;
use std::sync::mpsc::{Receiver, Sender};

use anyhow::{Context, Result};
use fips::identity::PeerIdentity;

/// The owner's devices, as the mesh knows them.
pub struct OwnDevices {
    /// Canonical npubs (re-encoded from their keys).
    pub npubs: Vec<String>,
    /// Their mesh addresses, which FIPS writes into each packet's IPv6 source
    /// from the authenticated session.
    pub addresses: HashSet<Ipv6Addr>,
}

impl OwnDevices {
    /// `None` for an empty list: the node is open, as before. Each npub is
    /// decoded and re-encoded, so no input can reach the config as text.
    pub fn parse(npubs: &[String]) -> Result<Option<Self>> {
        if npubs.is_empty() {
            return Ok(None);
        }
        let mut out = Self { npubs: Vec::new(), addresses: HashSet::new() };
        for npub in npubs {
            let id = PeerIdentity::from_npub(npub).with_context(|| format!("own device {npub:?}"))?;
            let npub = id.npub();
            if !out.npubs.contains(&npub) {
                out.addresses.insert(id.address().to_ipv6());
                out.npubs.push(npub);
            }
        }
        Ok(Some(out))
    }

    /// As [`Self::parse`], but `read_anyone` keeps own-devices mode on with
    /// an empty list: a phone with no other device still answers no one.
    pub fn parse_for(npubs: &[String], read_anyone: bool) -> Result<Option<Self>> {
        match Self::parse(npubs)? {
            None if read_anyone => Ok(Some(Self { npubs: Vec::new(), addresses: HashSet::new() })),
            own => Ok(own),
        }
    }

    pub fn contains(&self, npub: &str) -> bool {
        PeerIdentity::from_npub(npub).is_ok_and(|id| self.npubs.contains(&id.npub()))
    }

    /// The `rendezvous.nostr` line that answers offers from these npubs only.
    /// `me` is this node: with no devices it is the whole list, since FIPS
    /// reads an empty allowlist as none and would answer everyone.
    pub fn allowlist_yaml(&self, me: &str) -> String {
        let me = [me.to_string()];
        let npubs = if self.npubs.is_empty() { &me[..] } else { &self.npubs[..] };
        let list: Vec<String> = npubs.iter().map(|n| format!("\"{n}\"")).collect();
        format!("      offer_allowlist: [{}]\n", list.join(", "))
    }
}

/// The sender of a mesh packet, from its IPv6 source.
fn source(pkt: &[u8]) -> Option<Ipv6Addr> {
    if pkt.len() < 40 || pkt[0] >> 4 != 6 {
        return None;
    }
    let src: [u8; 16] = pkt[8..24].try_into().ok()?;
    Some(Ipv6Addr::from(src))
}

/// IPv6 next header for ICMPv6.
const ICMPV6: u8 = 58;

/// Passes own devices' packets to their stack, and everyone else's to the
/// strangers' stack (dropped without one). FIPS's own ICMPv6 (no route to a
/// peer) carries `me` as its source and goes to both, so a splice to a gone
/// peer resets instead of hanging; anything else from `me` is dropped, so
/// that source is no way into the owner's stack. Returns when the mesh or
/// own stack closes.
pub fn filter(
    from_mesh: Receiver<Vec<u8>>,
    me: Ipv6Addr,
    own: HashSet<Ipv6Addr>,
    to_stack: Sender<Vec<u8>>,
    to_strangers: Option<Sender<Vec<u8>>>,
) {
    for pkt in from_mesh {
        let Some(src) = source(&pkt) else { continue };
        if src == me {
            if pkt[6] != ICMPV6 {
                continue;
            }
            if let Some(s) = &to_strangers {
                let _ = s.send(pkt.clone());
            }
        } else if !own.contains(&src) {
            if let Some(s) = &to_strangers {
                let _ = s.send(pkt);
            }
            continue;
        }
        if to_stack.send(pkt).is_err() {
            return;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use fips::identity::Identity;

    fn v6(src: Ipv6Addr) -> Vec<u8> {
        let mut p = vec![0u8; 60];
        p[0] = 0x60;
        p[6] = 6; // TCP
        p[8..24].copy_from_slice(&src.octets());
        p
    }

    fn icmp6(src: Ipv6Addr) -> Vec<u8> {
        let mut p = v6(src);
        p[6] = ICMPV6;
        p
    }

    #[test]
    fn only_own_devices_and_this_node_reach_the_stack() {
        let own_dev: Ipv6Addr = "fd00::1".parse().unwrap();
        let stranger: Ipv6Addr = "fd00::2".parse().unwrap();
        let me: Ipv6Addr = "fd00::3".parse().unwrap();
        let (tx, rx) = std::sync::mpsc::channel();
        let (stack_tx, stack_rx) = std::sync::mpsc::channel();
        for p in [v6(own_dev), v6(stranger), icmp6(me), vec![0x45; 60], vec![0x60; 10]] {
            tx.send(p).unwrap();
        }
        drop(tx);
        filter(rx, me, HashSet::from([own_dev]), stack_tx, None);
        let passed: Vec<_> = stack_rx.try_iter().collect();
        assert_eq!(passed, vec![v6(own_dev), icmp6(me)]);
    }

    #[test]
    fn strangers_go_to_their_own_stack_never_to_the_owners() {
        let own_dev: Ipv6Addr = "fd00::1".parse().unwrap();
        let stranger: Ipv6Addr = "fd00::2".parse().unwrap();
        let me: Ipv6Addr = "fd00::3".parse().unwrap();
        let (tx, rx) = std::sync::mpsc::channel();
        let (stack_tx, stack_rx) = std::sync::mpsc::channel();
        let (strangers_tx, strangers_rx) = std::sync::mpsc::channel();
        for p in [v6(own_dev), v6(stranger), icmp6(me), vec![0x45; 60]] {
            tx.send(p).unwrap();
        }
        drop(tx);
        filter(rx, me, HashSet::from([own_dev]), stack_tx, Some(strangers_tx));
        assert_eq!(stack_rx.try_iter().collect::<Vec<_>>(), vec![v6(own_dev), icmp6(me)]);
        assert_eq!(strangers_rx.try_iter().collect::<Vec<_>>(), vec![v6(stranger), icmp6(me)]);
    }

    #[test]
    fn only_icmpv6_from_this_node_passes() {
        // FIPS writes `me` only on its own ICMPv6; any other protocol with
        // that source reaches neither stack.
        let own_dev: Ipv6Addr = "fd00::1".parse().unwrap();
        let me: Ipv6Addr = "fd00::3".parse().unwrap();
        let mut udp = v6(me);
        udp[6] = 17;
        let (tx, rx) = std::sync::mpsc::channel();
        let (stack_tx, stack_rx) = std::sync::mpsc::channel();
        let (strangers_tx, strangers_rx) = std::sync::mpsc::channel();
        for p in [v6(me), udp, icmp6(me)] {
            tx.send(p).unwrap();
        }
        drop(tx);
        filter(rx, me, HashSet::from([own_dev]), stack_tx, Some(strangers_tx));
        assert_eq!(stack_rx.try_iter().collect::<Vec<_>>(), vec![icmp6(me)]);
        assert_eq!(strangers_rx.try_iter().collect::<Vec<_>>(), vec![icmp6(me)]);
    }

    #[test]
    fn a_list_is_parsed_canonical_and_once() {
        assert!(OwnDevices::parse(&[]).unwrap().is_none(), "no list keeps the node open");
        let id = Identity::generate();
        let npub = id.npub();
        let other = Identity::generate().npub();
        let own = OwnDevices::parse(&[npub.clone(), npub.clone(), other.clone()]).unwrap().unwrap();
        assert_eq!(own.npubs, vec![npub.clone(), other.clone()]);
        assert_eq!(own.addresses.len(), 2);
        assert!(own.addresses.contains(&id.address().to_ipv6()));
        assert!(own.contains(&npub));
        assert!(!own.contains(&Identity::generate().npub()));
        assert!(!own.contains("npub1nope"));
        assert_eq!(own.allowlist_yaml("npub1me"), format!("      offer_allowlist: [\"{npub}\", \"{other}\"]\n"));
        // Something that is not an npub never reaches the config.
        let hostile = format!("{npub}\"]\n      policy: open #");
        assert!(OwnDevices::parse(&[hostile]).is_err());
    }

    #[test]
    fn the_config_answers_and_dials_own_devices_only() {
        let nsec = crate::generate_nsec();
        let (phone, page, friend) = (Identity::generate().npub(), Identity::generate().npub(), Identity::generate().npub());
        let opts = crate::StartOptions {
            own_devices: vec![phone.clone(), page.clone()],
            peers: vec![phone.clone()],
            ..Default::default()
        };
        let yaml = crate::config_yaml(&nsec, &opts).unwrap();
        assert!(yaml.contains(&format!("offer_allowlist: [\"{phone}\", \"{page}\"]")), "{}", yaml.as_str());
        let cfg: fips::Config = serde_yaml::from_str(&yaml).expect("parses");
        assert_eq!(cfg.node.rendezvous.nostr.offer_allowlist, vec![phone.clone(), page.clone()]);
        let dialed: Vec<_> = cfg.peers.iter().map(|p| p.npub.clone()).collect();
        assert_eq!(dialed, vec![phone.clone(), page], "each own device dialed once");
        assert!(!yaml.contains(&friend));
        assert!(cfg.node.leaf_only);

        // No list: no allowlist line, as before.
        let open = crate::config_yaml(&nsec, &crate::StartOptions::default()).unwrap();
        assert!(!open.contains("offer_allowlist"));
        let opts = crate::StartOptions { own_devices: vec!["npub1nope".into()], ..Default::default() };
        assert!(crate::config_yaml(&nsec, &opts).is_err());
        // Strangers are a part of own-devices mode: an open node has no door.
        let open_strangers = crate::StartOptions { strangers_port: 7778, ..Default::default() };
        assert!(crate::config_yaml(&nsec, &open_strangers).is_err());
        let with = crate::StartOptions { own_devices: vec![phone.clone()], strangers_port: 7778, public_seeds: true, ..Default::default() };
        let yaml = crate::config_yaml(&nsec, &with).unwrap();
        assert!(yaml.contains(&format!("offer_allowlist: [\"{phone}\"]")), "offers stay own-devices-only");
    }
}
