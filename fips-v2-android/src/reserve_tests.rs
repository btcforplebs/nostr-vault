//! Strangers filling the session table must not lock My Devices out (attack
//! review 2026-11-12, item 2). Real FIPS nodes on loopback UDP: a vault built
//! from the app's own `config_yaml`, strangers that each open a session to
//! it, then one of the owner's devices. The table is shrunk from 1024 to
//! `CAP` so the test needs `CAP` strangers instead of ~1,024 free keys; the
//! refusal path (`admit_new_entry`) is the same at any size.

use std::net::{Ipv6Addr, UdpSocket};
use std::sync::mpsc::Receiver;
use std::time::{Duration, Instant};

use fips::identity::{Identity, decode_nsec};

use crate::{StartOptions, config_yaml, generate_nsec, mesh_config, node};

/// The shrunk `max_sessions`: this many strangers fill the table.
const CAP: usize = 3;

fn free_udp_port() -> u16 {
    UdpSocket::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port()
}

fn npub_of(nsec: &str) -> String {
    Identity::from_secret_key(decode_nsec(nsec).unwrap()).npub()
}

/// A plain node that dials the vault at `vault_port` and nothing else.
fn dialer_yaml(nsec: &str, port: u16, vault_npub: &str, vault_port: u16) -> String {
    format!(
        r#"node:
  identity:
    nsec: "{nsec}"
  leaf_only: true
  control:
    enabled: false
  rendezvous:
    nostr:
      enabled: false
dns:
  enabled: false
transports:
  udp:
    bind_addr: "127.0.0.1:{port}"
peers:
  - npub: "{vault_npub}"
    addresses:
      - transport: udp
        addr: "127.0.0.1:{vault_port}"
    connect_policy: auto_connect
"#
    )
}

/// The app's vault config, made local: no Nostr, loopback UDP, own devices
/// at a fixed address instead of "nat", and the table shrunk to `CAP`.
fn local_vault_yaml(app_yaml: &str, port: u16, phone_port: u16) -> String {
    let y = app_yaml
        .replace("      enabled: true\n      advertise: true\n", "      enabled: false\n      advertise: false\n")
        .replace("    advertise_on_nostr: true\n", "    advertise_on_nostr: false\n")
        .replace(&format!("bind_addr: \"0.0.0.0:{port}\""), &format!("bind_addr: \"127.0.0.1:{port}\""))
        .replace("        addr: \"nat\"\n    via_nostr: true\n", &format!("        addr: \"127.0.0.1:{phone_port}\"\n    via_nostr: false\n"));
    let cap = format!("    max_sessions: {CAP}\n");
    if y.contains("  limits:\n") {
        y.replace("  limits:\n", &format!("  limits:\n{cap}"))
    } else {
        y.replace("  leaf_only: true\n", &format!("  leaf_only: true\n  limits:\n{cap}"))
    }
}

/// An IPv6/UDP packet from `src` to `dst`, port 9 (discard): enough for FIPS
/// to open a session and carry it.
fn packet(src: Ipv6Addr, dst: Ipv6Addr) -> Vec<u8> {
    let payload = b"hi";
    let udp_len = 8 + payload.len();
    let mut p = vec![0u8; 40 + udp_len];
    p[0] = 0x60;
    p[4..6].copy_from_slice(&(udp_len as u16).to_be_bytes());
    p[6] = 17;
    p[7] = 64;
    p[8..24].copy_from_slice(&src.octets());
    p[24..40].copy_from_slice(&dst.octets());
    p[40..42].copy_from_slice(&40000u16.to_be_bytes());
    p[42..44].copy_from_slice(&9u16.to_be_bytes());
    p[44..46].copy_from_slice(&(udp_len as u16).to_be_bytes());
    p[48..].copy_from_slice(payload);
    p
}

/// Send from `n` to the vault until the vault's TUN shows a packet from `n`.
fn reach(n: &node::Spawned, vault: &node::Spawned, vault_rx: &Receiver<Vec<u8>>, within: Duration) -> bool {
    let end = Instant::now() + within;
    while Instant::now() < end {
        let _ = n.tun.0.try_send(packet(n.address, vault.address));
        let poll_end = Instant::now() + Duration::from_millis(250);
        while let Some(left) = poll_end.checked_duration_since(Instant::now()) {
            match vault_rx.recv_timeout(left) {
                Ok(p) if p.len() >= 40 && p[8..24] == n.address.octets() => return true,
                Ok(_) => {}
                Err(_) => break,
            }
        }
    }
    false
}

struct Vault {
    node: node::Spawned,
    rx: Receiver<Vec<u8>>,
}

fn stop(n: node::Spawned) {
    let _ = n.stop.send(());
    let _ = n.thread.join();
}

/// Vault with one own device (the phone), `CAP` strangers holding the whole
/// table, then the phone. Returns whether the phone got through.
fn phone_reaches_a_full_vault() -> bool {
    let (vault_nsec, phone_nsec) = (generate_nsec(), generate_nsec());
    let (vault_npub, phone_npub) = (npub_of(&vault_nsec), npub_of(&phone_nsec));
    let (vault_port, phone_port) = (free_udp_port(), free_udp_port());

    let opts = StartOptions { own_devices: vec![phone_npub.clone()], udp_port: vault_port, read_anyone: true, ..Default::default() };
    let app_yaml = config_yaml(&vault_nsec, &opts).unwrap();
    let yaml = local_vault_yaml(&app_yaml, vault_port, phone_port);
    assert!(yaml.contains(&format!("max_sessions: {CAP}")), "{yaml}");
    let mut vault = node::spawn(mesh_config(&yaml).unwrap(), "test-vault").unwrap();
    let rx = std::mem::replace(&mut vault.tun.1, std::sync::mpsc::channel().1);
    let vault = Vault { node: vault, rx };

    // Strangers: each opens a session and is seen by the vault, so the table is full.
    let mut strangers = Vec::new();
    for i in 0..CAP {
        let nsec = generate_nsec();
        let cfg = mesh_config(&dialer_yaml(&nsec, free_udp_port(), &vault_npub, vault_port)).unwrap();
        let s = node::spawn(cfg, &format!("test-stranger-{i}")).unwrap();
        assert!(reach(&s, &vault.node, &vault.rx, Duration::from_secs(20)), "stranger {i} never reached the vault");
        strangers.push(s);
    }
    // One more stranger is refused: the table really is full.
    let extra_nsec = generate_nsec();
    let extra = node::spawn(mesh_config(&dialer_yaml(&extra_nsec, free_udp_port(), &vault_npub, vault_port)).unwrap(), "test-extra").unwrap();
    assert!(!reach(&extra, &vault.node, &vault.rx, Duration::from_secs(4)), "a stranger past the cap got in: the table is not full");

    let phone = node::spawn(mesh_config(&dialer_yaml(&phone_nsec, phone_port, &vault_npub, vault_port)).unwrap(), "test-phone").unwrap();
    let got_in = reach(&phone, &vault.node, &vault.rx, Duration::from_secs(20));

    for n in strangers.into_iter().chain([extra, phone]) {
        stop(n);
    }
    stop(vault.node);
    got_in
}

#[test]
fn own_device_reaches_a_vault_whose_session_table_strangers_filled() {
    assert!(phone_reaches_a_full_vault(), "strangers holding every session slot locked the owner's phone out");
}

#[test]
fn the_config_reserves_a_session_slot_for_each_own_device() {
    let nsec = generate_nsec();
    let (phone, mac) = (Identity::generate().npub(), Identity::generate().npub());
    let opts = StartOptions { own_devices: vec![phone.clone(), mac.clone(), phone.clone()], read_anyone: true, ..Default::default() };
    let cfg = mesh_config(&config_yaml(&nsec, &opts).unwrap()).unwrap();
    assert_eq!(cfg.node.limits.reserved_npubs, vec![phone, mac], "each own device reserved once");
    // Read-anyone with no devices: nothing to reserve, and never this node itself.
    let me = npub_of(&nsec);
    let lone = StartOptions { read_anyone: true, ..Default::default() };
    let cfg = mesh_config(&config_yaml(&nsec, &lone).unwrap()).unwrap();
    assert!(cfg.node.limits.reserved_npubs.is_empty(), "{:?}", cfg.node.limits.reserved_npubs);
    assert!(!cfg.node.limits.reserved_npubs.contains(&me));
    // An open node (no own devices) reserves nothing.
    let cfg = mesh_config(&config_yaml(&nsec, &StartOptions::default()).unwrap()).unwrap();
    assert!(cfg.node.limits.reserved_npubs.is_empty());
}
