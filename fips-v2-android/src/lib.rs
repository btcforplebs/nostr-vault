//! libnvfips: the FIPS mesh for the Nostr Vault Android app.
//!
//! Upstream FIPS runs in-process with an app-owned TUN, so the app needs no
//! VpnService and does not take the phone's one VPN slot. Mesh IPv6 packets
//! are terminated by fips-v2's userspace TCP/IP stack, which splices each mesh
//! connection to an ordinary localhost socket (the relay, or a local listener).
//!
//! The Kotlin side is `com.nostrvault.fips.FipsBridge`. Control plane only:
//! no packet ever crosses JNI.

// The probe's single-mode `run` and `Mode` go unused here.
#[allow(dead_code)]
#[path = "../../fips-v2/src/stack.rs"]
mod stack;

use std::net::{Ipv6Addr, SocketAddr};
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use fips::identity::{Identity, PeerIdentity, encode_nsec};
use fips::{Config, Node};
use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

/// The one mesh port a vault serves on. `stack.rs` reads it from the crate root.
pub const MESH_PORT: u16 = 80;

/// What the app passes to `start`, as JSON. Every field is optional.
#[derive(Deserialize, Default)]
#[serde(default)]
pub struct StartOptions {
    /// Npubs dialed at start. Anyone can reach this device; `ingress` adds
    /// any other npub on demand.
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
    /// Friends' vaults open for reading, each on a loopback port.
    reading: Vec<Reading>,
    counters: CountersOut,
}

#[derive(Serialize)]
struct Reading {
    npub: String,
    port: u16,
}

/// Served = friends reading this phone's relay; read = this phone reading
/// theirs. `_rx` is bytes from the mesh, `_tx` bytes sent to it.
#[derive(Serialize, Default)]
struct CountersOut {
    served_open: u64,
    served_total: u64,
    served_rx: u64,
    served_tx: u64,
    read_open: u64,
    read_total: u64,
    read_rx: u64,
    read_tx: u64,
}

impl CountersOut {
    fn from(c: &stack::Counters) -> Self {
        let get = |a: &std::sync::atomic::AtomicU64| a.load(Ordering::Relaxed);
        Self {
            served_open: get(&c.served_open),
            served_total: get(&c.served_total),
            served_rx: get(&c.served_rx),
            served_tx: get(&c.served_tx),
            read_open: get(&c.read_open),
            read_total: get(&c.read_total),
            read_rx: get(&c.read_rx),
            read_tx: get(&c.read_tx),
        }
    }
}

struct Running {
    npub: String,
    address: Ipv6Addr,
    started: Instant,
    /// The port being shared on the mesh; `None` while sharing is off.
    exported: Option<u16>,
    reading: Vec<Reading>,
    ctl: Arc<stack::Control>,
    /// Commands into the node's rx loop (adding a peer at runtime).
    control: tokio::sync::mpsc::Sender<fips::control::ControlMessage>,
    stack_thread: std::thread::JoinHandle<()>,
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
pub const ERR_BAD_NPUB: i32 = -6;

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
                let control = node.enable_embedded_control();
                let npub = node.npub();
                let address = node.identity().address().to_ipv6();
                let mtu = node.effective_ipv6_mtu() as usize;
                if let Err(e) = node.start().await {
                    let _ = ready_tx.send(Err(anyhow::anyhow!("start: {e}")));
                    return;
                }
                let _ = ready_tx.send(Ok((npub, address, mtu, tun, control)));
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

    let (npub, address, mtu, tun, control) = ready_rx
        .recv_timeout(Duration::from_secs(30))
        .context("node did not report ready")??;
    tracing::info!(%npub, %address, mtu, "fips mesh started");

    // One stack serves and reads over the TUN. It starts with sharing off.
    let ctl = stack::Control::new();
    let stack_ctl = ctl.clone();
    let (to_mesh, from_mesh) = tun;
    let stack_thread = std::thread::Builder::new().name("fips-stack".into()).spawn(move || {
        if let Err(e) = stack::run_with(address, mtu, to_mesh, from_mesh, &stack_ctl) {
            tracing::warn!("fips stack stopped: {e:#}");
        }
    });
    let stack_thread = match stack_thread {
        Ok(t) => t,
        Err(e) => {
            let _ = stop_tx.send(());
            let _ = node_thread.join();
            return Err(e.into());
        }
    };
    *state = Some(Running {
        npub,
        address,
        started: Instant::now(),
        exported: None,
        reading: Vec::new(),
        ctl,
        control,
        stack_thread,
        stop: stop_tx,
        node_thread,
    });
    Ok(())
}

/// Share a local TCP port (the relay, which also serves Blossom) on mesh :80.
/// Sharing one port at a time; a different port needs `unexport` first.
pub fn export(port: u16) -> i32 {
    let mut state = STATE.lock().unwrap();
    let Some(run) = state.as_mut() else { return ERR_NOT_RUNNING };
    match run.exported {
        Some(p) if p == port => return 0,
        Some(_) => return ERR_ALREADY_EXPORTED,
        None => {}
    }
    if !run.ctl.set_serve(Some(SocketAddr::from(([127, 0, 0, 1], port)))) {
        return ERR_START;
    }
    run.exported = Some(port);
    0
}

/// Stop sharing. Friends' connections in progress are cut; reading continues.
pub fn unexport() -> i32 {
    let mut state = STATE.lock().unwrap();
    let Some(run) = state.as_mut() else { return ERR_NOT_RUNNING };
    run.exported = None;
    if !run.ctl.set_serve(None) {
        return ERR_START;
    }
    0
}

/// A loopback port whose connections reach `npub`'s shared relay over the
/// mesh. The same npub gets the same port. Any npub works: one the node did
/// not start with is added as a peer, found through its Nostr advert.
/// Waits up to 10 s for the node: call it off the UI thread. At most 32
/// vaults stay open; opening one more closes the least recently read.
pub fn ingress(npub: &str) -> i32 {
    let control = match STATE.lock().unwrap().as_ref() {
        Some(run) => run.control.clone(),
        None => return ERR_NOT_RUNNING,
    };
    let Ok(peer) = PeerIdentity::from_npub(npub) else { return ERR_BAD_NPUB };
    // Outside the state lock: the rx loop answers, and never takes that lock.
    if let Err(e) = add_peer(&control, npub) {
        tracing::warn!("mesh add peer {npub}: {e:#}");
        return ERR_START;
    }
    let mut state = STATE.lock().unwrap();
    let Some(run) = state.as_mut() else { return ERR_NOT_RUNNING };
    match run.ctl.connect_port(peer.address().to_ipv6()) {
        Ok(port) => {
            // Most recently read last; past the cap the stalest listener goes,
            // matching the node's own cap on peers added this way.
            run.reading.retain(|r| r.npub != npub);
            run.reading.push(Reading { npub: npub.to_string(), port });
            while run.reading.len() > MAX_READING {
                let old = run.reading.remove(0);
                if let Ok(id) = PeerIdentity::from_npub(&old.npub) {
                    run.ctl.close_connect(id.address().to_ipv6());
                }
            }
            i32::from(port)
        }
        Err(e) => {
            tracing::warn!("mesh ingress {npub}: {e:#}");
            ERR_START
        }
    }
}

/// Vaults open for reading at once (the node keeps as many runtime peers).
const MAX_READING: usize = 32;

/// How long `ingress` waits for the node to take a new peer.
const ADD_PEER_TIMEOUT: Duration = Duration::from_secs(10);

/// Ask the node to dial `npub` through its advert. A known peer is a no-op.
fn add_peer(
    control: &tokio::sync::mpsc::Sender<fips::control::ControlMessage>,
    npub: &str,
) -> Result<()> {
    let request = fips::control::protocol::Request {
        command: "add_peer".into(),
        params: Some(serde_json::json!({ "npub": npub })),
    };
    let (tx, mut rx) = tokio::sync::oneshot::channel();
    let end = Instant::now() + ADD_PEER_TIMEOUT;
    // A full queue is a burst of opens, not a failure: wait for room.
    let mut message = (request, tx);
    loop {
        match control.try_send(message) {
            Ok(()) => break,
            Err(tokio::sync::mpsc::error::TrySendError::Full(m)) if Instant::now() < end => {
                message = m;
                std::thread::sleep(Duration::from_millis(5));
            }
            Err(e) => anyhow::bail!("node busy or stopped: {e}"),
        }
    }
    let response = loop {
        match rx.try_recv() {
            Ok(response) => break response,
            Err(tokio::sync::oneshot::error::TryRecvError::Closed) => anyhow::bail!("node stopped"),
            Err(tokio::sync::oneshot::error::TryRecvError::Empty) if Instant::now() < end => {
                std::thread::sleep(Duration::from_millis(5));
            }
            Err(_) => anyhow::bail!("node did not answer in {ADD_PEER_TIMEOUT:?}"),
        }
    };
    anyhow::ensure!(response.status == "ok", "{}", response.message.unwrap_or_default());
    Ok(())
}

/// Stop the node, and the stack with it.
pub fn stop() {
    let Some(run) = STATE.lock().unwrap().take() else { return };
    // Stack first, so its resets still have a node to leave through.
    run.ctl.stop();
    let _ = run.stack_thread.join();
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
            reading: Vec::new(),
            counters: CountersOut::default(),
        },
        Some(run) => Status {
            running: true,
            npub: Some(run.npub.clone()),
            address: Some(run.address.to_string()),
            uptime_s: run.started.elapsed().as_secs(),
            exported: run.exported.into_iter().collect(),
            peers: Vec::new(),
            reading: run.reading.iter().map(|r| Reading { npub: r.npub.clone(), port: r.port }).collect(),
            counters: CountersOut::from(&run.ctl.counters),
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

/// C ABI for the iOS app (Swift through a bridging header, `nvfips.h`).
/// Same calls and return codes as the JNI side. Returned strings are owned
/// by the caller and freed with `NvFipsFreeString`.
mod c_api {
    use super::*;
    use std::ffi::{CStr, CString, c_char};

    fn arg(p: *const c_char) -> Option<String> {
        if p.is_null() {
            return None;
        }
        // SAFETY: non-null, and the caller passes a NUL-terminated string.
        unsafe { CStr::from_ptr(p) }.to_str().ok().map(str::to_owned)
    }

    fn out(s: String) -> *mut c_char {
        CString::new(s).map(CString::into_raw).unwrap_or(std::ptr::null_mut())
    }

    /// A panic must not unwind into Swift; report it as a failure code.
    fn guarded<T>(fallback: T, f: impl FnOnce() -> T + std::panic::UnwindSafe) -> T {
        std::panic::catch_unwind(f).unwrap_or(fallback)
    }

    #[unsafe(no_mangle)]
    pub extern "C" fn NvFipsStart(nsec: *const c_char, options_json: *const c_char) -> i32 {
        init_logging();
        let Some(nsec) = arg(nsec).map(Zeroizing::new) else { return ERR_CONFIG };
        let opts_raw = arg(options_json).unwrap_or_default();
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
    pub extern "C" fn NvFipsGenerateNsec() -> *mut c_char {
        guarded(None, || Some(generate_nsec())).map_or(std::ptr::null_mut(), out)
    }

    #[unsafe(no_mangle)]
    pub extern "C" fn NvFipsStatusJSON() -> *mut c_char {
        out(guarded("{\"running\":false}".to_string(), status_json))
    }

    #[unsafe(no_mangle)]
    pub extern "C" fn NvFipsExport(port: u16) -> i32 {
        guarded(ERR_START, move || export(port))
    }

    #[unsafe(no_mangle)]
    pub extern "C" fn NvFipsUnexport() -> i32 {
        guarded(ERR_START, unexport)
    }

    #[unsafe(no_mangle)]
    pub extern "C" fn NvFipsIngress(npub: *const c_char) -> i32 {
        let Some(npub) = arg(npub) else { return ERR_BAD_NPUB };
        guarded(ERR_START, move || ingress(&npub))
    }

    #[unsafe(no_mangle)]
    pub extern "C" fn NvFipsStop() {
        guarded((), stop);
    }

    /// Free a string returned by this library. Null is ignored.
    #[unsafe(no_mangle)]
    pub extern "C" fn NvFipsFreeString(s: *mut c_char) {
        if !s.is_null() {
            // SAFETY: `s` came from `CString::into_raw` in `out`.
            drop(unsafe { CString::from_raw(s) });
        }
    }
}

#[cfg(target_os = "android")]
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
    pub extern "system" fn Java_com_nostrvault_fips_FipsBridge_nativeUnexport(
        _env: JNIEnv,
        _class: JClass,
    ) -> jint {
        guarded(ERR_START, unexport)
    }

    #[unsafe(no_mangle)]
    pub extern "system" fn Java_com_nostrvault_fips_FipsBridge_nativeIngress(
        mut env: JNIEnv,
        _class: JClass,
        npub: JString,
    ) -> jint {
        let Some(npub) = jstr(&mut env, &npub) else { return ERR_BAD_NPUB };
        guarded(ERR_START, move || ingress(&npub))
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
        let v: serde_json::Value = serde_json::from_str(&status_json()).unwrap();
        assert_eq!(v["running"], false);
        assert_eq!(v["exported"], serde_json::json!([]));
        assert_eq!(v["reading"], serde_json::json!([]));
        assert_eq!(v["counters"]["served_open"], 0);
        assert_eq!(v["counters"]["read_rx"], 0);
    }

    #[test]
    fn c_api_reports_codes_and_strings() {
        use std::ffi::{CStr, CString};
        let status = c_api::NvFipsStatusJSON();
        assert!(unsafe { CStr::from_ptr(status) }.to_str().unwrap().starts_with("{\"running\":false"));
        c_api::NvFipsFreeString(status);
        c_api::NvFipsFreeString(std::ptr::null_mut());
        let nsec = c_api::NvFipsGenerateNsec();
        assert!(unsafe { CStr::from_ptr(nsec) }.to_str().unwrap().starts_with("nsec1"));
        c_api::NvFipsFreeString(nsec);
        assert_eq!(c_api::NvFipsStart(std::ptr::null(), std::ptr::null()), ERR_CONFIG);
        let bad = CString::new("{not json").unwrap();
        let key = CString::new("nsec1x").unwrap();
        assert_eq!(c_api::NvFipsStart(key.as_ptr(), bad.as_ptr()), ERR_CONFIG);
        assert_eq!(c_api::NvFipsIngress(std::ptr::null()), ERR_BAD_NPUB);
        assert_eq!(c_api::NvFipsExport(4869), ERR_NOT_RUNNING);
    }

    #[test]
    fn a_closed_read_port_is_reopened_fresh() {
        let ctl = stack::Control::new();
        let peer: Ipv6Addr = "fd00::1".parse().unwrap();
        let first = ctl.connect_port(peer).unwrap();
        assert_eq!(ctl.connect_port(peer).unwrap(), first, "reused while open");
        ctl.close_connect(peer);
        assert!(ctl.connect_ports().is_empty());
        let second = ctl.connect_port(peer).unwrap();
        assert_ne!(second, first, "a fresh listener, not the closed one");
        ctl.close_connect("fd00::2".parse().unwrap()); // never opened: no-op
        assert_eq!(ctl.connect_ports(), vec![(peer, second)]);
    }

    #[test]
    fn ingress_and_unexport_need_a_running_node() {
        assert_eq!(unexport(), ERR_NOT_RUNNING);
        assert_eq!(ingress("npub1nope"), ERR_NOT_RUNNING);
    }

    // Two stacks wired TUN to TUN in-process, no FIPS node: what the stack
    // does with sharing, reading, counters and stop.
    mod two_stacks {
        use crate::stack::{self, Control};
        use std::io::{Read, Write};
        use std::net::{Ipv6Addr, SocketAddr, TcpListener, TcpStream};
        use std::sync::Arc;
        use std::sync::atomic::{AtomicBool, Ordering};
        use std::thread::JoinHandle;
        use std::time::{Duration, Instant};

        const A: Ipv6Addr = Ipv6Addr::new(0xfd00, 0, 0, 0, 0, 0, 0, 0xa);
        const B: Ipv6Addr = Ipv6Addr::new(0xfd00, 0, 0, 0, 0, 0, 0, 0xb);

        struct Side {
            ctl: Arc<Control>,
            thread: JoinHandle<()>,
            /// Set to drop every packet between the two sides, as a lost path would.
            cut: Arc<AtomicBool>,
        }

        /// Start stacks at A and B; each one's outbound packets are the other's inbound.
        fn pair() -> (Side, Side) {
            let (a_out, mut a_out_rx) = tokio::sync::mpsc::channel::<Vec<u8>>(1024);
            let (b_out, mut b_out_rx) = tokio::sync::mpsc::channel::<Vec<u8>>(1024);
            let (a_in_tx, a_in) = std::sync::mpsc::channel();
            let (b_in_tx, b_in) = std::sync::mpsc::channel();
            let cut = Arc::new(AtomicBool::new(false));
            let (cut_ab, cut_ba) = (cut.clone(), cut.clone());
            std::thread::spawn(move || {
                while let Some(p) = a_out_rx.blocking_recv() {
                    if cut_ab.load(Ordering::Relaxed) {
                        continue;
                    }
                    let _ = b_in_tx.send(p);
                }
            });
            std::thread::spawn(move || {
                while let Some(p) = b_out_rx.blocking_recv() {
                    if cut_ba.load(Ordering::Relaxed) {
                        continue;
                    }
                    let _ = a_in_tx.send(p);
                }
            });
            let side = |addr, out, inbound| {
                let ctl = Control::new();
                let c = ctl.clone();
                let thread = std::thread::spawn(move || stack::run_with(addr, 1280, out, inbound, &c).unwrap());
                Side { ctl, thread, cut: cut.clone() }
            };
            (side(A, a_out, a_in), side(B, b_out, b_in))
        }

        /// A local "relay" that answers each line with `tag` + the line.
        fn relay(tag: &'static str) -> SocketAddr {
            let l = TcpListener::bind("127.0.0.1:0").unwrap();
            let addr = l.local_addr().unwrap();
            std::thread::spawn(move || {
                for mut s in l.incoming().flatten() {
                    std::thread::spawn(move || {
                        let mut buf = [0u8; 4096];
                        while let Ok(n) = s.read(&mut buf) {
                            if n == 0 {
                                break;
                            }
                            let mut reply = tag.as_bytes().to_vec();
                            reply.extend_from_slice(&buf[..n]);
                            if s.write_all(&reply).is_err() {
                                break;
                            }
                        }
                    });
                }
            });
            addr
        }

        fn open(port: u16) -> TcpStream {
            let s = TcpStream::connect(("127.0.0.1", port)).unwrap();
            s.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
            s
        }

        fn ask(s: &mut TcpStream, msg: &str) -> std::io::Result<String> {
            s.write_all(msg.as_bytes())?;
            let mut buf = [0u8; 256];
            let n = s.read(&mut buf)?;
            if n == 0 {
                return Err(std::io::ErrorKind::UnexpectedEof.into());
            }
            Ok(String::from_utf8_lossy(&buf[..n]).into_owned())
        }

        fn wait_for(what: &str, f: impl Fn() -> bool) {
            let end = Instant::now() + Duration::from_secs(5);
            while !f() {
                assert!(Instant::now() < end, "timed out waiting for {what}");
                std::thread::sleep(Duration::from_millis(10));
            }
        }

        #[test]
        fn share_read_toggle_count_and_stop() {
            let (a, b) = pair();
            a.ctl.set_serve(Some(relay("A:")));
            b.ctl.set_serve(Some(relay("B:")));

            // Share and read at once: each side reads the other over one TUN.
            let to_b = a.ctl.connect_port(B).unwrap();
            let to_a = b.ctl.connect_port(A).unwrap();
            assert_eq!(a.ctl.connect_port(B).unwrap(), to_b, "same peer, same port");
            let mut ab = open(to_b);
            let mut ba = open(to_a);
            assert_eq!(ask(&mut ab, "ping").unwrap(), "B:ping");
            assert_eq!(ask(&mut ba, "pong").unwrap(), "A:pong");

            let (ca, cb) = (&a.ctl.counters, &b.ctl.counters);
            let get = |x: &std::sync::atomic::AtomicU64| x.load(Ordering::Relaxed);
            assert_eq!((get(&ca.read_total), get(&ca.served_total)), (1, 1));
            assert_eq!((get(&cb.read_total), get(&cb.served_total)), (1, 1));
            assert_eq!((get(&ca.read_open), get(&ca.served_open)), (1, 1));
            assert_eq!(get(&ca.read_tx), 4, "A sent ping");
            assert_eq!(get(&cb.served_rx), 4, "B received ping");
            assert_eq!(get(&cb.served_tx), 6, "B answered B:ping");
            assert_eq!(get(&ca.read_rx), 6, "A received B:ping");

            // B stops sharing: A's open read is cut, a new one is refused, and
            // B's own read of A carries on.
            b.ctl.set_serve(None);
            assert!(ask(&mut ab, "again").is_err(), "open connection survives sharing off");
            let mut refused = open(to_b);
            assert!(ask(&mut refused, "knock").is_err(), "new connection while sharing off");
            assert_eq!(ask(&mut ba, "still").unwrap(), "A:still");
            wait_for("B served_open = 0", || get(&cb.served_open) == 0);

            // Sharing back on, without restarting anything.
            b.ctl.set_serve(Some(relay("B2:")));
            let mut again = open(to_b);
            assert_eq!(ask(&mut again, "hi").unwrap(), "B2:hi");

            // Stop ends both threads and resets what is open.
            a.ctl.stop();
            b.ctl.stop();
            wait_for("stack threads to end", || a.thread.is_finished() && b.thread.is_finished());
            a.thread.join().unwrap();
            b.thread.join().unwrap();
            assert!(ask(&mut again, "gone").is_err(), "connection survives stop");
            assert_eq!(get(&ca.read_open) + get(&cb.served_open), 0);
        }

        #[test]
        fn read_of_a_silent_peer_gives_up() {
            let (a, b) = pair();
            // Nothing answers for this address: B's stack drops what is not its own.
            let nobody = a.ctl.connect_port(Ipv6Addr::new(0xfd00, 0, 0, 0, 0, 0, 0, 0xc)).unwrap();
            let mut s = open(nobody);
            let get = |x: &std::sync::atomic::AtomicU64| x.load(Ordering::Relaxed);
            wait_for("the read to open", || get(&a.ctl.counters.read_open) == 1);
            assert!(ask(&mut s, "anyone?").is_err(), "a read to nobody must fail");
            wait_for("read_open back to 0", || get(&a.ctl.counters.read_open) == 0);

            // An answered read idles past the connect timeout without being cut.
            b.ctl.set_serve(Some(relay("B:")));
            let mut ok = open(a.ctl.connect_port(B).unwrap());
            assert_eq!(ask(&mut ok, "one").unwrap(), "B:one");
            std::thread::sleep(Duration::from_millis(1500));
            assert_eq!(ask(&mut ok, "two").unwrap(), "B:two");
            a.ctl.stop();
            b.ctl.stop();
        }

        #[test]
        fn a_friend_who_vanishes_is_let_go() {
            let (a, b) = pair();
            b.ctl.set_serve(Some(relay("B:")));
            let mut s = open(a.ctl.connect_port(B).unwrap());
            assert_eq!(ask(&mut s, "hi").unwrap(), "B:hi");
            let get = |x: &std::sync::atomic::AtomicU64| x.load(Ordering::Relaxed);

            // Idle but alive: keep-alive answers, nothing is cut.
            std::thread::sleep(Duration::from_secs(4));
            assert_eq!(ask(&mut s, "still").unwrap(), "B:still");

            // The path goes silent, with no FIN or RST: both ends give up.
            a.cut.store(true, Ordering::Relaxed);
            let end = Instant::now() + Duration::from_secs(10);
            while get(&a.ctl.counters.read_open) + get(&b.ctl.counters.served_open) > 0 {
                assert!(Instant::now() < end, "a vanished friend holds the splice open");
                std::thread::sleep(Duration::from_millis(50));
            }
            a.ctl.stop();
            b.ctl.stop();
        }

        #[test]
        fn a_relay_that_is_down_costs_nothing() {
            let (a, b) = pair();
            // Nothing listens on the forward port.
            let dead = TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap();
            b.ctl.set_serve(Some(dead));
            let to_b = a.ctl.connect_port(B).unwrap();
            for _ in 0..3 {
                assert!(ask(&mut open(to_b), "x").is_err());
            }
            let get = |x: &std::sync::atomic::AtomicU64| x.load(Ordering::Relaxed);
            assert_eq!(get(&b.ctl.counters.served_total), 0);
            wait_for("only the armed listeners to be left", || b.ctl.socket_count() == 4);
            a.ctl.stop();
            b.ctl.stop();
        }
    }
}
