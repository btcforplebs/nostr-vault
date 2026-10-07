//! libnvfips: the FIPS mesh for the Nostr Vault Android app.
//!
//! Upstream FIPS runs in-process with an app-owned TUN, so the app needs no
//! VpnService and does not take the phone's one VPN slot. Mesh IPv6 packets
//! are terminated by fips-v2's userspace TCP/IP stack, which splices each mesh
//! connection to an ordinary localhost socket (the relay, or a local listener).
//!
//! The Kotlin side is `com.nostrvault.fips.FipsBridge`. Control plane only:
//! no packet ever crosses JNI.

// Connect mode is unused until step 3 (reading a friend's vault).
#[allow(dead_code)]
#[path = "../../fips-v2/src/stack.rs"]
mod stack;

use std::net::{Ipv6Addr, SocketAddr};
use std::sync::Mutex;
use std::sync::mpsc::Receiver;
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use fips::identity::{Identity, encode_nsec};
use fips::upper::tun::TunOutboundTx;
use fips::{Config, Node};
use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

/// The one mesh port a vault serves on. `stack.rs` reads it from the crate root.
pub const MESH_PORT: u16 = 80;

/// What the app passes to `start`, as JSON. Every field is optional.
#[derive(Deserialize, Default)]
#[serde(default)]
pub struct StartOptions {
    /// Npubs allowed to reach this device (configured_only policy).
    pub peers: Vec<String>,
    /// Advert and signaling relays. Empty keeps upstream's defaults.
    pub relays: Vec<String>,
    /// Local UDP port; 0 lets the OS choose.
    pub udp_port: u16,
    /// Offer private LAN addresses to peers (same-network testing only).
    pub lan: bool,
}

#[derive(Serialize)]
struct Status {
    running: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    npub: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    address: Option<String>,
    uptime_s: u64,
    exported: Vec<u16>,
    peers: Vec<String>,
}

struct Running {
    npub: String,
    address: Ipv6Addr,
    mtu: usize,
    started: Instant,
    exported: Vec<u16>,
    /// Handed to the stack on the first export; `None` once it is running.
    tun: Option<(TunOutboundTx, Receiver<Vec<u8>>)>,
    stop: tokio::sync::oneshot::Sender<()>,
    node_thread: std::thread::JoinHandle<()>,
}

static STATE: Mutex<Option<Running>> = Mutex::new(None);

/// How long an offer stays valid and how long we wait for its answer. Upstream
/// defaults to 120 s, which is also how long a missed offer stalls a connect
/// (the glare path drops the peer's offer while ours goes unanswered).
const SIGNAL_TTL_SECS: u64 = 30;

pub const ERR_CONFIG: i32 = -1;
pub const ERR_UNSUPPORTED: i32 = -2;
pub const ERR_NOT_RUNNING: i32 = -3;
pub const ERR_ALREADY_EXPORTED: i32 = -4;
pub const ERR_START: i32 = -5;

fn config_yaml(nsec: &str, opts: &StartOptions) -> Zeroizing<String> {
    let relays = if opts.relays.is_empty() {
        String::new()
    } else {
        let list: Vec<String> = opts.relays.iter().map(|r| format!("\"{r}\"")).collect();
        format!("      advert_relays: [{0}]\n      dm_relays: [{0}]\n", list.join(", "))
    };
    let mut peers = String::new();
    for npub in &opts.peers {
        peers.push_str(&format!(
            "  - npub: \"{npub}\"\n    addresses:\n      - transport: udp\n        addr: \"nat\"\n    via_nostr: true\n    connect_policy: auto_connect\n"
        ));
    }
    let peers = if peers.is_empty() { "peers: []\n".to_string() } else { format!("peers:\n{peers}") };
    // The control socket binds under /tmp, which an app sandbox cannot write.
    Zeroizing::new(format!(
        r#"node:
  identity:
    nsec: "{nsec}"
  leaf_only: true
  control:
    enabled: false
  rendezvous:
    nostr:
      enabled: true
      advertise: true
      policy: configured_only
      share_local_candidates: {lan}
      signal_ttl_secs: {SIGNAL_TTL_SECS}
{relays}dns:
  enabled: false
transports:
  udp:
    bind_addr: "0.0.0.0:{port}"
    advertise_on_nostr: true
    public: false
{peers}"#,
        lan = opts.lan,
        port = opts.udp_port,
    ))
}

pub fn generate_nsec() -> String {
    encode_nsec(&Identity::generate().keypair().secret_key())
}

/// Start the node. Idempotent: an already-running node returns Ok.
pub fn start(nsec: &str, opts: &StartOptions) -> Result<()> {
    let mut state = STATE.lock().unwrap();
    if state.is_some() {
        return Ok(());
    }
    let yaml = config_yaml(nsec, opts);
    let config: Config = serde_yaml::from_str(&yaml).context("mesh config")?;
    drop(yaml);

    // The node lives on its own thread and runtime: `start` must run inside a
    // runtime, and the rx loop then owns the node until it is told to stop.
    let (ready_tx, ready_rx) = std::sync::mpsc::channel();
    let (stop_tx, stop_rx) = tokio::sync::oneshot::channel::<()>();
    let node_thread = std::thread::Builder::new()
        .name("fips-node".into())
        .spawn(move || {
            let rt = match tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .build()
            {
                Ok(rt) => rt,
                Err(e) => {
                    let _ = ready_tx.send(Err(anyhow::anyhow!("runtime: {e}")));
                    return;
                }
            };
            rt.block_on(async move {
                let mut node = match Node::new(config) {
                    Ok(n) => n,
                    Err(e) => {
                        let _ = ready_tx.send(Err(anyhow::anyhow!("Node::new: {e}")));
                        return;
                    }
                };
                let tun = node.enable_app_owned_tun();
                let npub = node.npub();
                let address = node.identity().address().to_ipv6();
                let mtu = node.effective_ipv6_mtu() as usize;
                if let Err(e) = node.start().await {
                    let _ = ready_tx.send(Err(anyhow::anyhow!("start: {e}")));
                    return;
                }
                let _ = ready_tx.send(Ok((npub, address, mtu, tun)));
                if let Err(e) = node
                    .run_rx_loop_with_shutdown(async {
                        let _ = stop_rx.await;
                    })
                    .await
                {
                    tracing::warn!("fips rx loop ended: {e}");
                }
                if let Err(e) = node.stop().await {
                    tracing::warn!("fips stop: {e}");
                }
            });
        })?;

    let (npub, address, mtu, tun) = ready_rx
        .recv_timeout(Duration::from_secs(30))
        .context("node did not report ready")??;
    tracing::info!(%npub, %address, mtu, "fips mesh started");
    *state = Some(Running {
        npub,
        address,
        mtu,
        started: Instant::now(),
        exported: Vec::new(),
        tun: Some(tun),
        stop: stop_tx,
        node_thread,
    });
    Ok(())
}

/// Offer a local TCP port (the relay, which also serves Blossom) on mesh :80.
pub fn export(port: u16) -> i32 {
    let mut state = STATE.lock().unwrap();
    let Some(run) = state.as_mut() else { return ERR_NOT_RUNNING };
    if run.exported.contains(&port) {
        return 0;
    }
    // fips-v2's stack drives one mode per TUN and does not yet take a second
    // port or a connect listener alongside a serve.
    let Some((to_mesh, from_mesh)) = run.tun.take() else { return ERR_ALREADY_EXPORTED };
    let (addr, mtu) = (run.address, run.mtu);
    let forward = SocketAddr::from(([127, 0, 0, 1], port));
    let spawned = std::thread::Builder::new().name("fips-stack".into()).spawn(move || {
        if let Err(e) = stack::run(addr, mtu, to_mesh, from_mesh, stack::Mode::Serve { forward }) {
            tracing::warn!("fips stack stopped: {e:#}");
        }
    });
    if spawned.is_err() {
        return ERR_START;
    }
    run.exported.push(port);
    0
}

/// Stop the node. The stack thread has no stop signal yet (fips-v2 stack.rs
/// loops forever); it idles once the node is gone, and is reclaimed with the
/// process.
pub fn stop() {
    let Some(run) = STATE.lock().unwrap().take() else { return };
    let _ = run.stop.send(());
    let _ = run.node_thread.join();
    tracing::info!("fips mesh stopped");
}

pub fn status_json() -> String {
    let state = STATE.lock().unwrap();
    let status = match state.as_ref() {
        None => Status {
            running: false,
            npub: None,
            address: None,
            uptime_s: 0,
            exported: Vec::new(),
            peers: Vec::new(),
        },
        Some(run) => Status {
            running: true,
            npub: Some(run.npub.clone()),
            address: Some(run.address.to_string()),
            uptime_s: run.started.elapsed().as_secs(),
            exported: run.exported.clone(),
            peers: Vec::new(),
        },
    };
    serde_json::to_string(&status).unwrap_or_else(|_| "{\"running\":false}".into())
}

pub fn init_logging() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        use tracing_subscriber::prelude::*;
        let filter = tracing_subscriber::EnvFilter::try_from_default_env()
            .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info,nostr_relay_pool=warn"));
        #[cfg(target_os = "android")]
        let _ = tracing_subscriber::registry()
            .with(filter)
            .with(tracing_android::layer("FipsMesh").ok())
            .try_init();
        #[cfg(not(target_os = "android"))]
        let _ = tracing_subscriber::registry()
            .with(filter)
            .with(tracing_subscriber::fmt::layer())
            .try_init();
    });
}

mod jni_api {
    use super::*;
    use jni::JNIEnv;
    use jni::objects::{JClass, JString};
    use jni::sys::{jint, jstring};

    fn jstr(env: &mut JNIEnv, s: &JString) -> Option<String> {
        env.get_string(s).ok().map(Into::into)
    }

    fn out(env: &mut JNIEnv, s: String) -> jstring {
        env.new_string(s).map(|s| s.into_raw()).unwrap_or(std::ptr::null_mut())
    }

    /// A panic must not unwind across JNI; report it as a failure code.
    fn guarded<T>(fallback: T, f: impl FnOnce() -> T + std::panic::UnwindSafe) -> T {
        std::panic::catch_unwind(f).unwrap_or(fallback)
    }

    #[unsafe(no_mangle)]
    pub extern "system" fn Java_com_nostrvault_fips_FipsBridge_nativeStart(
        mut env: JNIEnv,
        _class: JClass,
        nsec: JString,
        options_json: JString,
    ) -> jint {
        init_logging();
        let Some(nsec) = jstr(&mut env, &nsec).map(Zeroizing::new) else { return ERR_CONFIG };
        let opts_raw = jstr(&mut env, &options_json).unwrap_or_default();
        let opts: StartOptions = if opts_raw.trim().is_empty() {
            StartOptions::default()
        } else {
            match serde_json::from_str(&opts_raw) {
                Ok(o) => o,
                Err(e) => {
                    tracing::warn!("mesh options: {e}");
                    return ERR_CONFIG;
                }
            }
        };
        guarded(ERR_START, move || match start(&nsec, &opts) {
            Ok(()) => 0,
            Err(e) => {
                tracing::warn!("mesh start failed: {e:#}");
                ERR_START
            }
        })
    }

    #[unsafe(no_mangle)]
    pub extern "system" fn Java_com_nostrvault_fips_FipsBridge_nativeGenerateNsec(
        mut env: JNIEnv,
        _class: JClass,
    ) -> jstring {
        let nsec = guarded(None, || Some(generate_nsec()));
        match nsec {
            Some(n) => out(&mut env, n),
            None => std::ptr::null_mut(),
        }
    }

    #[unsafe(no_mangle)]
    pub extern "system" fn Java_com_nostrvault_fips_FipsBridge_nativeStatusJSON(
        mut env: JNIEnv,
        _class: JClass,
    ) -> jstring {
        let s = guarded("{\"running\":false}".to_string(), status_json);
        out(&mut env, s)
    }

    #[unsafe(no_mangle)]
    pub extern "system" fn Java_com_nostrvault_fips_FipsBridge_nativeExport(
        _env: JNIEnv,
        _class: JClass,
        port: jint,
    ) -> jint {
        let Ok(port) = u16::try_from(port) else { return ERR_CONFIG };
        guarded(ERR_START, move || export(port))
    }

    #[unsafe(no_mangle)]
    pub extern "system" fn Java_com_nostrvault_fips_FipsBridge_nativeIngress(
        _env: JNIEnv,
        _class: JClass,
        _npub: JString,
    ) -> jint {
        // Reading a friend's vault is step 3; it needs connect listeners in
        // the same stack as the serve.
        ERR_UNSUPPORTED
    }

    #[unsafe(no_mangle)]
    pub extern "system" fn Java_com_nostrvault_fips_FipsBridge_nativeStop(
        _env: JNIEnv,
        _class: JClass,
    ) {
        guarded((), stop);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn config_parses_with_and_without_peers() {
        let nsec = generate_nsec();
        for peers in [vec![], vec!["npub15mrkrlapfs52syawrthvyfhg349pkjd8zdkk6qfc4unj5jgxfwqsjmp6wn".to_string()]] {
            let opts = StartOptions { peers, relays: vec!["wss://nos.lol".into()], ..Default::default() };
            let yaml = config_yaml(&nsec, &opts);
            let cfg: Config = serde_yaml::from_str(&yaml).expect("parses");
            assert!(!cfg.node.control.enabled);
            assert_eq!(cfg.node.rendezvous.nostr.signal_ttl_secs, SIGNAL_TTL_SECS);
            assert!(cfg.node.leaf_only, "a phone must never carry other nodes' traffic");
            assert_eq!(cfg.peers.len(), opts.peers.len());
        }
    }

    #[test]
    fn status_is_stopped_before_start() {
        assert_eq!(status_json(), r#"{"running":false,"uptime_s":0,"exported":[],"peers":[]}"#);
    }
}
