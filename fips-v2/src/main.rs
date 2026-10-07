//! fipsv2-probe: milestone-1 spike for Nostr Vault FIPS v2.
//!
//! Embeds upstream FIPS in-process with an app-owned TUN and terminates the
//! mesh IPv6 traffic in a userspace TCP/IP stack (smoltcp). No VPN, no system
//! TUN, no transit seed: peers are introduced by Nostr-relay-signalled
//! `udp:nat` traversal.
//!
//!   serve   --peer <npub> --forward 127.0.0.1:3355   mesh port 80 -> local TCP
//!   connect --peer <npub> --listen  127.0.0.1:4000   local TCP -> peer's mesh port 80
//!
//! Both sides must name each other with `--peer` (configured_only policy).

// The app's runtime controls (fips-v2-android) go unused here.
#[allow(dead_code)]
mod stack;

use anyhow::{Context, Result, bail};
use fips::identity::{Identity, PeerIdentity, encode_nsec};
use fips::{Config, Node};
use std::net::SocketAddr;
use std::path::PathBuf;

pub const MESH_PORT: u16 = 80;

struct Args {
    mode: String,
    peer: String,
    local: SocketAddr,
    state: PathBuf,
    udp_port: u16,
    relays: Vec<String>,
    lan: bool,
}

fn parse_args() -> Result<Args> {
    let mut it = std::env::args().skip(1);
    let mode = it.next().context("usage: fipsv2-probe serve|connect --peer <npub> ...")?;
    let mut peer = None;
    let mut local = None;
    let mut state = None;
    let mut udp_port = 2121;
    let mut relays = Vec::new();
    let mut lan = false;
    while let Some(flag) = it.next() {
        if flag == "--lan" {
            lan = true;
            continue;
        }
        let value = it.next().with_context(|| format!("{flag} needs a value"))?;
        match flag.as_str() {
            "--peer" => peer = Some(value),
            "--forward" | "--listen" => local = Some(value.parse()?),
            "--state" => state = Some(PathBuf::from(value)),
            "--udp-port" => udp_port = value.parse()?,
            "--relay" => relays.push(value),
            _ => bail!("unknown flag {flag}"),
        }
    }
    if mode != "serve" && mode != "connect" {
        bail!("mode must be serve or connect");
    }
    Ok(Args {
        peer: peer.context("--peer <npub> is required")?,
        local: local.context("--forward/--listen addr is required")?,
        state: state.unwrap_or_else(|| PathBuf::from(format!(".fipsv2-{mode}"))),
        udp_port,
        relays,
        lan,
        mode,
    })
}

/// Load or create this probe's identity (nsec kept in the state dir).
fn load_nsec(state: &PathBuf) -> Result<String> {
    std::fs::create_dir_all(state)?;
    let path = state.join("nsec");
    if let Ok(nsec) = std::fs::read_to_string(&path) {
        return Ok(nsec.trim().to_string());
    }
    let nsec = encode_nsec(&Identity::generate().keypair().secret_key());
    std::fs::write(&path, &nsec)?;
    Ok(nsec)
}

fn build_config(args: &Args, nsec: &str) -> Result<Config> {
    let relays = if args.relays.is_empty() {
        String::new()
    } else {
        let list: Vec<String> = args.relays.iter().map(|r| format!("\"{r}\"")).collect();
        format!(
            "      advert_relays: [{0}]\n      dm_relays: [{0}]\n",
            list.join(", ")
        )
    };
    let yaml = format!(
        r#"node:
  identity:
    nsec: "{nsec}"
  control:
    enabled: false
  rendezvous:
    nostr:
      enabled: true
      advertise: true
      policy: configured_only
      share_local_candidates: {lan}
{relays}dns:
  enabled: false
transports:
  udp:
    bind_addr: "0.0.0.0:{port}"
    advertise_on_nostr: true
    public: false
peers:
  - npub: "{peer}"
    alias: "vault-peer"
    addresses:
      - transport: udp
        addr: "nat"
    via_nostr: true
    connect_policy: auto_connect
"#,
        port = args.udp_port,
        lan = args.lan,
        peer = args.peer,
    );
    let path = args.state.join("fips.yaml");
    std::fs::write(&path, yaml)?;
    Ok(Config::load_file(&path)?)
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "info,fips=info".into()),
        )
        .init();

    let args = parse_args()?;
    let nsec = load_nsec(&args.state)?;
    let config = build_config(&args, &nsec)?;
    let peer_addr = PeerIdentity::from_npub(&args.peer)?.address().to_ipv6();

    let mut node = Node::new(config)?;
    let (to_mesh, from_mesh) = node.enable_app_owned_tun();
    let my_addr = node.identity().address().to_ipv6();
    let mtu = node.effective_ipv6_mtu();
    println!("npub      {}", node.npub());
    println!("mesh addr {my_addr}  (mtu {mtu})");
    println!("peer addr {peer_addr}");

    node.start().await?;

    let mode = match args.mode.as_str() {
        "serve" => stack::Mode::Serve { forward: args.local },
        _ => stack::Mode::Connect { listen: args.local, peer: peer_addr },
    };
    std::thread::spawn(move || {
        if let Err(e) = stack::run(my_addr, mtu as usize, to_mesh, from_mesh, mode) {
            eprintln!("stack stopped: {e:#}");
            std::process::exit(1);
        }
    });

    node.run_rx_loop_with_shutdown(async {
        let _ = tokio::signal::ctrl_c().await;
    })
    .await?;
    node.stop().await?;
    Ok(())
}
