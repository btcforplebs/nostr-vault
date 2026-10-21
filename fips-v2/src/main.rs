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
//! Traversal offers are answered only from those npubs (offer_allowlist), so
//! this node's public address goes to no one else. `serve` takes `--peer`
//! once per own device; only those reach `--forward`.
//!
//! `serve --blobs` also links to the public seeds, so anyone on the mesh can
//! read a blob by hash through them (`GET /<sha256>`), without ever learning
//! this node's address. Their connections never reach `--forward` as is: a
//! gate asks it only for `GET`/`HEAD /<sha256>[.ext]`, checks the bytes
//! against the hash, and turns everything else away (no listing, no upload,
//! no relay).

// The app's runtime controls (fips-v2-android) go unused here.
#[allow(dead_code)]
mod stack;

use anyhow::{Context, Result, bail};
use fips::identity::{Identity, PeerIdentity, encode_nsec};
use fips::{Config, Node};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::io::{ErrorKind, Read, Write};
use std::net::{Ipv6Addr, SocketAddr, TcpListener, TcpStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::{Receiver, Sender};
use std::sync::Arc;
use std::time::Duration;

pub const MESH_PORT: u16 = 80;

/// `fips-v2-android/src/relay_link.rs` PUBLIC_SEEDS: keep the two in step.
const SEEDS: &[(&str, &str)] = &[
    ("npub1927ye6w57stma7yntatltdphes2fugdn8ktqdmp72225crrvgwqq4p7rkd", "fips1.iris.to:51820"),
    ("npub1zv3qmj7xz7znehyqwzpc26fcjxtcf7tpxeevxx93ymgm6kw7gjpqp9npvh", "fips2.iris.to:51820"),
];

struct Args {
    mode: String,
    peers: Vec<String>,
    local: SocketAddr,
    state: PathBuf,
    udp_port: u16,
    relays: Vec<String>,
    lan: bool,
    blobs: bool,
}

fn parse_args() -> Result<Args> {
    let mut it = std::env::args().skip(1);
    let mode = it.next().context("usage: fipsv2-probe serve|connect --peer <npub> ...")?;
    let mut peers = Vec::new();
    let mut local = None;
    let mut state = None;
    let mut udp_port = 2121;
    let mut relays = Vec::new();
    let mut lan = false;
    let mut blobs = false;
    while let Some(flag) = it.next() {
        if flag == "--lan" {
            lan = true;
            continue;
        }
        if flag == "--blobs" {
            blobs = true;
            continue;
        }
        let value = it.next().with_context(|| format!("{flag} needs a value"))?;
        match flag.as_str() {
            "--peer" => peers.push(PeerIdentity::from_npub(&value)?.npub()),
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
    if peers.is_empty() {
        bail!("--peer <npub> is required");
    }
    if mode == "connect" && (peers.len() > 1 || blobs) {
        bail!("connect takes one --peer and no --blobs");
    }
    Ok(Args {
        peers,
        local: local.context("--forward/--listen addr is required")?,
        state: state.unwrap_or_else(|| PathBuf::from(format!(".fipsv2-{mode}"))),
        udp_port,
        relays,
        lan,
        blobs,
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

fn config_yaml(args: &Args, nsec: &str) -> String {
    let relays = if args.relays.is_empty() {
        String::new()
    } else {
        let list: Vec<String> = args.relays.iter().map(|r| format!("\"{r}\"")).collect();
        format!(
            "      advert_relays: [{0}]\n      dm_relays: [{0}]\n",
            list.join(", ")
        )
    };
    let allowlist: Vec<String> = args.peers.iter().map(|p| format!("\"{p}\"")).collect();
    let mut peers = String::new();
    for (i, peer) in args.peers.iter().enumerate() {
        peers.push_str(&format!(
            "  - npub: \"{peer}\"\n    alias: \"vault-peer-{i}\"\n    addresses:\n      - transport: udp\n        addr: \"nat\"\n    via_nostr: true\n    connect_policy: auto_connect\n"
        ));
    }
    // Readers by hash come through the seeds; a leaf carries no one else's
    // traffic.
    let leaf = if args.blobs {
        for (npub, addr) in SEEDS {
            peers.push_str(&format!(
                "  - npub: \"{npub}\"\n    addresses:\n      - transport: udp\n        addr: \"{addr}\"\n    connect_policy: auto_connect\n"
            ));
        }
        "  leaf_only: true\n"
    } else {
        ""
    };
    format!(
        r#"node:
  identity:
    nsec: "{nsec}"
{leaf}  control:
    enabled: false
  rendezvous:
    nostr:
      enabled: true
      advertise: true
      policy: configured_only
      offer_allowlist: [{allowlist}]
      share_local_candidates: {lan}
{relays}dns:
  enabled: false
transports:
  udp:
    bind_addr: "0.0.0.0:{port}"
    advertise_on_nostr: true
    public: false
peers:
{peers}"#,
        port = args.udp_port,
        lan = args.lan,
        allowlist = allowlist.join(", "),
    )
}

fn build_config(args: &Args, nsec: &str) -> Result<Config> {
    let path = args.state.join("fips.yaml");
    std::fs::write(&path, config_yaml(args, nsec))?;
    Ok(Config::load_file(&path)?)
}

/// The sender of a mesh packet: FIPS writes the session's (authenticated)
/// address into the IPv6 source, so this is who it is, not who it claims.
fn source(pkt: &[u8]) -> Option<Ipv6Addr> {
    if pkt.len() < 40 || pkt[0] >> 4 != 6 {
        return None;
    }
    let src: [u8; 16] = pkt[8..24].try_into().ok()?;
    Some(Ipv6Addr::from(src))
}

/// Own devices' packets to one stack, everyone else's to the other (or
/// nowhere without `--blobs`), so a stranger's TCP never meets the relay.
fn demux(from_mesh: Receiver<Vec<u8>>, own: HashSet<Ipv6Addr>, to_own: Sender<Vec<u8>>, to_others: Option<Sender<Vec<u8>>>) {
    for pkt in from_mesh {
        let to = match source(&pkt) {
            Some(src) if own.contains(&src) => Some(&to_own),
            Some(_) => to_others.as_ref(),
            None => None,
        };
        if let Some(to) = to
            && to.send(pkt).is_err()
        {
            return;
        }
    }
}

/// Bytes of a request head a gate reads before giving up on it.
const GATE_HEAD_MAX: usize = 8 * 1024;
/// Readers by hash served at once; more get 503.
const GATE_MAX_OPEN: usize = 32;
/// Connections one stranger may hold open in the blob stack.
const GATE_PER_PEER_OPEN: usize = 4;
/// Bytes one stranger may pull per helper run.
const GATE_PER_PEER_BYTES: u64 = 1 << 30;
/// Whole-request and whole-reply deadlines, so a trickling stranger cannot
/// hold a gate slot past them.
const GATE_HEAD_DEADLINE: Duration = Duration::from_secs(10);
const GATE_REPLY_DEADLINE: Duration = Duration::from_secs(600);

/// What a stranger's request head asks for, or the status that turns it away.
#[derive(Debug, PartialEq)]
enum Ask {
    Blob { head_only: bool, path: String, sha: String },
    Refuse(u16),
}

/// `GET`/`HEAD /<sha256>[.ext]` and nothing else. `None` until the head is
/// complete.
fn parse_ask(buf: &[u8]) -> Option<Ask> {
    let end = buf.windows(4).position(|w| w == b"\r\n\r\n")?;
    let head = std::str::from_utf8(&buf[..end]).unwrap_or("");
    let mut parts = head.lines().next().unwrap_or("").split(' ');
    let (Some(method), Some(target), Some(version), None) = (parts.next(), parts.next(), parts.next(), parts.next()) else {
        return Some(Ask::Refuse(400));
    };
    if !version.starts_with("HTTP/1.") {
        return Some(Ask::Refuse(400));
    }
    let head_only = match method {
        "GET" => false,
        "HEAD" => true,
        _ => return Some(Ask::Refuse(405)),
    };
    let path = target.split(['?', '#']).next().unwrap_or("");
    let Some(name) = path.strip_prefix('/') else { return Some(Ask::Refuse(404)) };
    let (hash, ext) = match name.split_once('.') {
        Some((h, e)) => (h, Some(e)),
        None => (name, None),
    };
    let ext_ok = ext.is_none_or(|e| (1..=10).contains(&e.len()) && e.bytes().all(|b| b.is_ascii_alphanumeric()));
    if hash.len() != 64 || !hash.bytes().all(|b| b.is_ascii_hexdigit()) || !ext_ok {
        return Some(Ask::Refuse(404));
    }
    let sha = hash.to_ascii_lowercase();
    let path = match ext {
        Some(e) => format!("/{sha}.{}", e.to_ascii_lowercase()),
        None => format!("/{sha}"),
    };
    Some(Ask::Blob { head_only, path, sha })
}

fn refuse(stream: &mut TcpStream, code: u16) {
    let reason = match code {
        400 => "Bad Request",
        404 => "Not Found",
        405 => "Method Not Allowed",
        503 => "Service Unavailable",
        _ => "Bad Gateway",
    };
    let _ = stream.write_all(format!("HTTP/1.1 {code} {reason}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").as_bytes());
}

/// The relay's answer head: status, length, type. Anything else it says
/// stays here.
struct RelayHead {
    status: u16,
    length: Option<u64>,
    content_type: Option<String>,
    chunked: bool,
}

fn parse_relay_head(head: &str) -> Option<RelayHead> {
    let mut lines = head.split("\r\n");
    let status = lines.next()?.split(' ').nth(1)?.parse().ok()?;
    let mut out = RelayHead { status, length: None, content_type: None, chunked: false };
    for line in lines {
        let Some((k, v)) = line.split_once(':') else { continue };
        let v = v.trim();
        match k.trim().to_ascii_lowercase().as_str() {
            "content-length" => out.length = v.parse().ok(),
            "transfer-encoding" => out.chunked = !v.eq_ignore_ascii_case("identity"),
            // Only a plain media type goes back out.
            "content-type" if v.len() <= 100 && v.bytes().all(|b| b.is_ascii_alphanumeric() || b"/+.-; =".contains(&b)) => {
                out.content_type = Some(v.to_string())
            }
            _ => {}
        }
    }
    Some(out)
}

/// Serve one stranger: read its ask, fetch exactly that blob from `relay`,
/// and pass the bytes on only if they hash to the name. The last chunk is
/// held back until the hash is checked, so bad bytes end in a short body.
fn serve_ask(mut client: TcpStream, relay: SocketAddr) -> Result<()> {
    client.set_read_timeout(Some(Duration::from_secs(10)))?;
    client.set_write_timeout(Some(Duration::from_secs(60)))?;
    let mut buf = Vec::new();
    let mut chunk = [0u8; 64 * 1024];
    let head_until = std::time::Instant::now() + GATE_HEAD_DEADLINE;
    let ask = loop {
        if let Some(ask) = parse_ask(&buf) {
            break ask;
        }
        if std::time::Instant::now() > head_until {
            return Ok(());
        }
        if buf.len() > GATE_HEAD_MAX {
            break Ask::Refuse(400);
        }
        match client.read(&mut chunk[..GATE_HEAD_MAX + 1 - buf.len().min(GATE_HEAD_MAX)]) {
            Ok(0) => return Ok(()),
            Ok(n) => buf.extend_from_slice(&chunk[..n]),
            Err(e) => return Err(e.into()),
        }
    };
    let (head_only, path, sha) = match ask {
        Ask::Blob { head_only, path, sha } => (head_only, path, sha),
        Ask::Refuse(code) => {
            println!("blob gate refused {code}");
            refuse(&mut client, code);
            return Ok(());
        }
    };

    let mut up = match TcpStream::connect_timeout(&relay, Duration::from_secs(3)) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("blob gate: relay {relay}: {e}");
            refuse(&mut client, 502);
            return Ok(());
        }
    };
    up.set_read_timeout(Some(Duration::from_secs(30)))?;
    let method = if head_only { "HEAD" } else { "GET" };
    up.write_all(format!("{method} {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n").as_bytes())?;

    let mut head = Vec::new();
    let body_start = loop {
        if let Some(i) = head.windows(4).position(|w| w == b"\r\n\r\n") {
            break i + 4;
        }
        if head.len() > 16 * 1024 {
            refuse(&mut client, 502);
            return Ok(());
        }
        match up.read(&mut chunk)? {
            0 => {
                refuse(&mut client, 502);
                return Ok(());
            }
            n => head.extend_from_slice(&chunk[..n]),
        }
    };
    let rh = parse_relay_head(std::str::from_utf8(&head[..body_start]).unwrap_or(""));
    let Some(rh) = rh.filter(|h| h.status == 200) else {
        refuse(&mut client, 404);
        return Ok(());
    };
    let (Some(length), false) = (rh.length, rh.chunked) else {
        refuse(&mut client, 502);
        return Ok(());
    };
    let content_type = rh.content_type.as_deref().unwrap_or("application/octet-stream");
    client.write_all(
        format!(
            "HTTP/1.1 200 OK\r\nContent-Type: {content_type}\r\nContent-Length: {length}\r\nCache-Control: public, max-age=604800, immutable\r\nConnection: close\r\n\r\n"
        )
        .as_bytes(),
    )?;
    if head_only {
        println!("blob gate HEAD {sha} {length}");
        return Ok(());
    }

    let mut hasher = Sha256::new();
    let mut got: u64 = 0;
    let mut held: Vec<u8> = head[body_start..].to_vec();
    let reply_until = std::time::Instant::now() + GATE_REPLY_DEADLINE;
    while got + (held.len() as u64) < length {
        if std::time::Instant::now() > reply_until {
            eprintln!("blob gate: {sha} past its deadline; cut");
            let _ = socket2::SockRef::from(&client).set_linger(Some(Duration::ZERO));
            return Ok(());
        }
        let n = match up.read(&mut chunk) {
            Ok(n) => n,
            Err(e) if e.kind() == ErrorKind::Interrupted => continue,
            Err(e) => return Err(e.into()),
        };
        if n == 0 {
            break;
        }
        hasher.update(&held);
        got += held.len() as u64;
        client.write_all(&held)?;
        held.clear();
        held.extend_from_slice(&chunk[..n]);
    }
    hasher.update(&held);
    got += held.len() as u64;
    let hex: String = hasher.finalize().iter().map(|b| format!("{b:02x}")).collect();
    if got != length || hex != sha {
        eprintln!("blob gate: {sha} from relay hashed {hex} ({got}/{length} bytes); cut");
        let _ = socket2::SockRef::from(&client).set_linger(Some(Duration::ZERO));
        return Ok(());
    }
    client.write_all(&held)?;
    println!("blob gate GET {sha} {length}");
    Ok(())
}

/// A loopback listener the strangers' stack forwards to.
fn start_gate(relay: SocketAddr) -> Result<SocketAddr> {
    let listener = TcpListener::bind(("127.0.0.1", 0)).context("bind blob gate")?;
    let addr = listener.local_addr()?;
    let open = Arc::new(AtomicUsize::new(0));
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            if open.fetch_add(1, Ordering::SeqCst) >= GATE_MAX_OPEN {
                open.fetch_sub(1, Ordering::SeqCst);
                refuse(&mut stream, 503);
                continue;
            }
            let open = open.clone();
            std::thread::spawn(move || {
                if let Err(e) = serve_ask(stream, relay) {
                    eprintln!("blob gate: {e:#}");
                }
                open.fetch_sub(1, Ordering::SeqCst);
            });
        }
    });
    Ok(addr)
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
    let peer_addrs = args
        .peers
        .iter()
        .map(|p| Ok(PeerIdentity::from_npub(p)?.address().to_ipv6()))
        .collect::<Result<Vec<Ipv6Addr>>>()?;

    let mut node = Node::new(config)?;
    let (to_mesh, from_mesh) = node.enable_app_owned_tun();
    let my_addr = node.identity().address().to_ipv6();
    let mtu = node.effective_ipv6_mtu() as usize;
    println!("npub      {}", node.npub());
    println!("mesh addr {my_addr}  (mtu {mtu})");
    for addr in &peer_addrs {
        println!("peer addr {addr}");
    }

    node.start().await?;

    let fail = |e: anyhow::Error| {
        eprintln!("stack stopped: {e:#}");
        std::process::exit(1);
    };
    if args.mode == "serve" {
        let (to_own, own_rx) = std::sync::mpsc::channel();
        let mut others = None;
        if args.blobs {
            let gate = start_gate(args.local)?;
            println!("blob gate {gate} -> {} (GET/HEAD /<sha256> only)", args.local);
            let (to_others, others_rx) = std::sync::mpsc::channel();
            let ctl = stack::Control::new();
            ctl.set_limits(stack::ServeLimits {
                per_peer_open: GATE_PER_PEER_OPEN,
                per_peer_bytes: GATE_PER_PEER_BYTES,
                ..Default::default()
            });
            let (tx, c) = (to_mesh.clone(), ctl.clone());
            std::thread::spawn(move || {
                if let Err(e) = stack::run_with(my_addr, mtu, tx, others_rx, &c) {
                    fail(e);
                }
            });
            ctl.set_serve(Some(gate));
            others = Some(to_others);
        }
        let own: HashSet<Ipv6Addr> = peer_addrs.iter().copied().collect();
        std::thread::spawn(move || demux(from_mesh, own, to_own, others));
        let forward = args.local;
        std::thread::spawn(move || {
            if let Err(e) = stack::run(my_addr, mtu, to_mesh, own_rx, stack::Mode::Serve { forward }) {
                fail(e);
            }
        });
    } else {
        let mode = stack::Mode::Connect { listen: args.local, peer: peer_addrs[0] };
        std::thread::spawn(move || {
            if let Err(e) = stack::run(my_addr, mtu, to_mesh, from_mesh, mode) {
                fail(e);
            }
        });
    }

    node.run_rx_loop_with_shutdown(async {
        let _ = tokio::signal::ctrl_c().await;
    })
    .await?;
    node.stop().await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    const SHA: &str = "fa57db80dd7d5acf5a1d8a52883d42119f95252a18df07658c5312d9157b1ab0";

    fn ask(head: &str) -> Option<Ask> {
        parse_ask(head.as_bytes())
    }

    fn blob(head_only: bool, path: &str) -> Option<Ask> {
        Some(Ask::Blob { head_only, path: path.into(), sha: SHA.into() })
    }

    #[test]
    fn only_a_hash_path_is_asked_for() {
        assert_eq!(ask(&format!("GET /{SHA} HTTP/1.1\r\nHost: x\r\n\r\n")), blob(false, &format!("/{SHA}")));
        assert_eq!(ask(&format!("HEAD /{SHA}.JPG HTTP/1.1\r\n\r\n")), blob(true, &format!("/{SHA}.jpg")));
        let upper = SHA.to_ascii_uppercase();
        assert_eq!(ask(&format!("GET /{upper}?x=1 HTTP/1.0\r\n\r\n")), blob(false, &format!("/{SHA}")));

        for path in [
            "/".to_string(),
            format!("/list/{SHA}"),
            "/upload".into(),
            "/mirror".into(),
            format!("/{}", &SHA[1..]),
            format!("/{SHA}0"),
            format!("/{SHA}/../x"),
            format!("/{SHA}.j/g"),
            format!("/{SHA}.toolongextension"),
            format!("/{}g", &SHA[1..]),
            format!("//{SHA}"),
        ] {
            assert_eq!(ask(&format!("GET {path} HTTP/1.1\r\n\r\n")), Some(Ask::Refuse(404)), "{path}");
        }
        for method in ["PUT", "POST", "DELETE", "OPTIONS"] {
            assert_eq!(ask(&format!("{method} /{SHA} HTTP/1.1\r\n\r\n")), Some(Ask::Refuse(405)));
        }
        assert_eq!(ask(&format!("GET /{SHA} SPDY\r\n\r\n")), Some(Ask::Refuse(400)));
        assert_eq!(ask("GET /a b HTTP/1.1\r\n\r\n"), Some(Ask::Refuse(400)));
        // A websocket upgrade to the relay is just another non-hash path.
        assert_eq!(ask("GET / HTTP/1.1\r\nUpgrade: websocket\r\n\r\n"), Some(Ask::Refuse(404)));
        assert_eq!(ask(&format!("GET /{SHA} HTTP/1.1\r\n")), None);
    }

    fn v6(src: Ipv6Addr) -> Vec<u8> {
        let mut p = vec![0u8; 60];
        p[0] = 0x60;
        p[8..24].copy_from_slice(&src.octets());
        p
    }

    #[test]
    fn own_devices_and_strangers_land_in_different_stacks() {
        let own_dev: Ipv6Addr = "fd00::1".parse().unwrap();
        let stranger: Ipv6Addr = "fd00::2".parse().unwrap();
        for blobs in [true, false] {
            let (tx, rx) = std::sync::mpsc::channel();
            let (own_tx, own_rx) = std::sync::mpsc::channel();
            let (oth_tx, oth_rx) = std::sync::mpsc::channel();
            for p in [v6(own_dev), v6(stranger), vec![0x45; 60], vec![0x60; 10]] {
                tx.send(p).unwrap();
            }
            drop(tx);
            demux(rx, HashSet::from([own_dev]), own_tx, blobs.then_some(oth_tx));
            let own: Vec<_> = own_rx.try_iter().collect();
            let oth: Vec<_> = oth_rx.try_iter().collect();
            assert_eq!(own, vec![v6(own_dev)]);
            assert_eq!(oth, if blobs { vec![v6(stranger)] } else { vec![] });
        }
    }

    /// A stand-in relay: answers every request with `reply`, and records
    /// the request heads it got.
    fn fake_relay(reply: Vec<u8>) -> (SocketAddr, Arc<Mutex<Vec<String>>>) {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = l.local_addr().unwrap();
        let seen = Arc::new(Mutex::new(Vec::new()));
        let s = seen.clone();
        std::thread::spawn(move || {
            for mut c in l.incoming().flatten() {
                let mut head = Vec::new();
                let mut buf = [0u8; 4096];
                while !head.windows(4).any(|w| w == b"\r\n\r\n") {
                    match c.read(&mut buf) {
                        Ok(0) | Err(_) => break,
                        Ok(n) => head.extend_from_slice(&buf[..n]),
                    }
                }
                s.lock().unwrap().push(String::from_utf8_lossy(&head).into_owned());
                let _ = c.write_all(&reply);
            }
        });
        (addr, seen)
    }

    fn ok_reply(body: &[u8], extra: &str) -> Vec<u8> {
        let mut r = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: image/jpeg\r\nContent-Length: {}\r\nX-Relay-Secret: 1\r\n{extra}\r\n",
            body.len()
        )
        .into_bytes();
        r.extend_from_slice(body);
        r
    }

    /// Status, headers and body the gate gives a stranger, or how it failed.
    fn fetch(gate: SocketAddr, req: &str) -> std::io::Result<(String, Vec<u8>)> {
        let mut c = TcpStream::connect(gate)?;
        c.write_all(req.as_bytes())?;
        let mut out = Vec::new();
        c.read_to_end(&mut out)?;
        let end = out.windows(4).position(|w| w == b"\r\n\r\n").expect("head") + 4;
        Ok((String::from_utf8_lossy(&out[..end]).into_owned(), out[end..].to_vec()))
    }

    fn body_and_sha() -> (Vec<u8>, String) {
        let body: Vec<u8> = (0..300_000u32).map(|i| (i * 7 + i / 251) as u8).collect();
        let sha: String = Sha256::digest(&body).iter().map(|b| format!("{b:02x}")).collect();
        (body, sha)
    }

    #[test]
    fn a_stranger_gets_the_blob_and_only_its_type_and_length() {
        let (body, sha) = body_and_sha();
        let (relay, seen) = fake_relay(ok_reply(&body, ""));
        let gate = start_gate(relay).unwrap();

        let (head, got) = fetch(gate, &format!("GET /{sha}.jpg HTTP/1.1\r\nCookie: a\r\nAuthorization: Nostr x\r\n\r\n")).unwrap();
        assert!(head.starts_with("HTTP/1.1 200 OK\r\n"), "{head}");
        assert!(head.contains("Content-Type: image/jpeg\r\n"));
        assert!(head.contains(&format!("Content-Length: {}\r\n", body.len())));
        assert!(!head.contains("X-Relay-Secret"));
        assert!(got == body, "{} of {} bytes", got.len(), body.len());

        // The relay is asked for that path alone; the stranger's headers stay out.
        let asked = seen.lock().unwrap()[0].clone();
        assert_eq!(asked, format!("GET /{sha}.jpg HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"));

        let (head, got) = fetch(gate, &format!("HEAD /{sha} HTTP/1.1\r\n\r\n")).unwrap();
        assert!(head.starts_with("HTTP/1.1 200 OK\r\n"));
        assert!(got.is_empty());
        assert!(seen.lock().unwrap()[1].starts_with(&format!("HEAD /{sha} ")));
    }

    #[test]
    fn a_relay_that_keeps_the_socket_open_still_delivers() {
        let (body, sha) = body_and_sha();
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let relay = l.local_addr().unwrap();
        let reply = ok_reply(&body, "");
        std::thread::spawn(move || {
            let (mut c, _) = l.accept().unwrap();
            let _ = c.read(&mut [0u8; 4096]);
            c.write_all(&reply).unwrap();
            std::thread::sleep(Duration::from_secs(60));
        });
        let gate = start_gate(relay).unwrap();
        let t = std::time::Instant::now();
        let (_, got) = fetch(gate, &format!("GET /{sha} HTTP/1.1\r\n\r\n")).unwrap();
        assert!(got == body);
        assert!(t.elapsed() < Duration::from_secs(5));
    }

    #[test]
    fn listing_upload_and_the_relay_itself_never_reach_the_relay() {
        let (body, _) = body_and_sha();
        let (relay, seen) = fake_relay(ok_reply(&body, ""));
        let gate = start_gate(relay).unwrap();
        for req in [
            "GET / HTTP/1.1\r\n\r\n".to_string(),
            "GET / HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n".into(),
            format!("GET /list/{SHA} HTTP/1.1\r\n\r\n"),
            "PUT /upload HTTP/1.1\r\nContent-Length: 1\r\n\r\nx".into(),
            format!("DELETE /{SHA} HTTP/1.1\r\n\r\n"),
            format!("GET /{SHA}/.. HTTP/1.1\r\n\r\n"),
        ] {
            let (head, got) = fetch(gate, &req).unwrap();
            assert!(head.starts_with("HTTP/1.1 4"), "{req}: {head}");
            assert!(got.is_empty());
        }
        assert!(seen.lock().unwrap().is_empty());
    }

    #[test]
    fn bytes_that_do_not_match_the_hash_end_short() {
        let (body, _) = body_and_sha();
        let wrong_sha = SHA; // the relay sends `body`, which hashes to something else
        let (relay, _) = fake_relay(ok_reply(&body, ""));
        let gate = start_gate(relay).unwrap();
        match fetch(gate, &format!("GET /{wrong_sha} HTTP/1.1\r\n\r\n")) {
            Ok((head, got)) => {
                assert!(head.contains(&format!("Content-Length: {}", body.len())));
                assert!(got.len() < body.len(), "the held-back tail must not go out");
            }
            Err(e) => assert_eq!(e.kind(), ErrorKind::ConnectionReset),
        }
    }

    #[test]
    fn a_relay_miss_or_odd_answer_is_a_plain_error() {
        let (body, sha) = body_and_sha();
        let cases = [
            (b"HTTP/1.1 404 Not Found\r\nContent-Length: 14\r\n\r\nfile not found".to_vec(), "404"),
            (b"HTTP/1.1 302 Found\r\nLocation: https://elsewhere/\r\nContent-Length: 0\r\n\r\n".to_vec(), "404"),
            (b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n".to_vec(), "502"),
            (ok_reply(&body, "Content-Type: text/html<script>\r\n"), "200"),
        ];
        for (reply, want) in cases {
            let (relay, _) = fake_relay(reply);
            let gate = start_gate(relay).unwrap();
            let (head, got) = fetch(gate, &format!("GET /{sha} HTTP/1.1\r\n\r\n")).unwrap();
            assert!(head.starts_with(&format!("HTTP/1.1 {want}")), "{head}");
            assert!(!head.contains("Location") && !head.contains("<script>"));
            if want != "200" {
                assert!(got.is_empty());
            }
        }
        // Nothing listening: 502, not a hang.
        let dead = TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap();
        let gate = start_gate(dead).unwrap();
        let (head, _) = fetch(gate, &format!("GET /{sha} HTTP/1.1\r\n\r\n")).unwrap();
        assert!(head.starts_with("HTTP/1.1 502"), "{head}");
    }

    fn npub() -> String {
        Identity::generate().npub()
    }

    fn args(peers: Vec<String>, blobs: bool, state: PathBuf) -> Args {
        Args {
            mode: "serve".into(),
            peers,
            local: "127.0.0.1:3355".parse().unwrap(),
            state,
            udp_port: 0,
            relays: vec![],
            lan: false,
            blobs,
        }
    }

    #[test]
    fn offers_are_answered_from_own_devices_only_and_seeds_come_with_blobs() {
        let state = std::env::temp_dir().join(format!("fipsv2-cfg-{}", std::process::id()));
        std::fs::create_dir_all(&state).unwrap();
        let nsec = encode_nsec(&Identity::generate().keypair().secret_key());
        let (phone, pad) = (npub(), npub());
        for blobs in [false, true] {
            let a = args(vec![phone.clone(), pad.clone()], blobs, state.clone());
            let yaml = config_yaml(&a, &nsec);
            assert!(yaml.contains(&format!("offer_allowlist: [\"{phone}\", \"{pad}\"]")), "{yaml}");
            assert!(yaml.contains("policy: configured_only"));
            assert_eq!(yaml.contains("leaf_only: true"), blobs);
            for (seed, _) in SEEDS {
                assert_eq!(yaml.contains(seed), blobs);
            }
            let cfg = build_config(&a, &nsec).unwrap();
            assert_eq!(cfg.peers.len(), 2 + if blobs { SEEDS.len() } else { 0 });
        }
        std::fs::remove_dir_all(&state).unwrap();
    }
}
