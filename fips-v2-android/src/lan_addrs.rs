//! `StartOptions::lan_addrs`: the LAN addresses a box behind a container
//! bridge (StartOS) offers its own devices instead of its interfaces'.

use anyhow::{Context, Result};

/// The `local_candidate_ips` YAML line for `addrs`, or "" when empty. Each
/// entry is parsed as an IP address, so nothing else reaches the template.
pub(crate) fn candidates_yaml(addrs: &[String], lan: bool) -> Result<String> {
    let mut ips: Vec<String> = Vec::new();
    for a in addrs {
        let ip: std::net::IpAddr = a.trim().parse().with_context(|| format!("LAN address {a:?}"))?;
        anyhow::ensure!(
            !(ip.is_unspecified() || ip.is_loopback() || ip.is_multicast()),
            "LAN address {ip} is not one a phone on the LAN can reach"
        );
        if !ips.contains(&ip.to_string()) {
            ips.push(ip.to_string());
        }
    }
    anyhow::ensure!(ips.is_empty() || lan, "lan_addrs needs lan");
    if ips.is_empty() {
        return Ok(String::new());
    }
    let list: Vec<String> = ips.iter().map(|ip| serde_json::Value::from(ip.as_str()).to_string()).collect();
    Ok(format!("      local_candidate_ips: [{}]\n", list.join(", ")))
}

#[cfg(test)]
mod tests {
    use crate::*;

    #[test]
    fn lan_addrs_become_the_local_candidates() {
        let nsec = generate_nsec();
        let opts = StartOptions {
            lan: true,
            lan_addrs: vec![" 192.168.4.82".into(), "192.168.4.82".into(), "fd00::5".into()],
            ..Default::default()
        };
        let config = mesh_config(&config_yaml(&nsec, &opts).unwrap()).unwrap();
        let n = &config.node.rendezvous.nostr;
        assert!(n.share_local_candidates);
        let want: Vec<std::net::IpAddr> = vec!["192.168.4.82".parse().unwrap(), "fd00::5".parse().unwrap()];
        assert_eq!(n.local_candidate_ips, want);
        // None set: the interfaces, as before.
        let config = mesh_config(&config_yaml(&nsec, &StartOptions { lan: true, ..Default::default() }).unwrap()).unwrap();
        assert!(config.node.rendezvous.nostr.local_candidate_ips.is_empty());
    }

    #[test]
    fn a_bad_lan_addr_stops_the_mesh_config() {
        let nsec = generate_nsec();
        for bad in ["umbrel.local", "192.168.4.82:8080", "127.0.0.1", "0.0.0.0", "\"]\n      advertise: false"] {
            let opts = StartOptions { lan: true, lan_addrs: vec![bad.into()], ..Default::default() };
            assert!(config_yaml(&nsec, &opts).is_err(), "{bad:?} must be refused");
        }
        let opts = StartOptions { lan: false, lan_addrs: vec!["192.168.4.82".into()], ..Default::default() };
        assert!(config_yaml(&nsec, &opts).is_err(), "lan_addrs without lan is refused, not ignored");
    }
}
