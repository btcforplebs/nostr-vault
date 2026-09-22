//! C ABI for the FIPS bridge.
//!
//! Deliberately control-plane only. The dataplane — loopback listeners, quinn,
//! the FIPS pump — never crosses this boundary, because video at 8 Mbps is ~830
//! datagrams/sec each way and per-packet FFI would be fatal on both Swift (ARC)
//! and Android (a Java array per packet, straight into GC pressure).
//!
//! Conventions mirror the existing Go FFI in `libhaven.h`: `char*` in and out,
//! caller frees via `FipsBridgeFreeString`, `int` status codes, NULL/negative on
//! error, every export wrapped in `catch_unwind`.

use std::ffi::{c_char, c_int, CStr, CString};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Instant;

use fips_bridge_core::proxy::{egress, Ingress};
use fips_bridge_core::{bind_endpoint, EndpointOptions, FipsQuic};
use fips_endpoint::PeerIdentity;
use tokio::net::TcpListener;
use tokio::runtime::Runtime;

const SCOPE: &str = "nostr-vault-fips";

struct Bridge {
    runtime: Runtime,
    quic: Arc<FipsQuic>,
    npub: String,
    address: String,
    started: Instant,
}

static BRIDGE: OnceLock<Mutex<Option<Bridge>>> = OnceLock::new();

fn slot() -> &'static Mutex<Option<Bridge>> {
    BRIDGE.get_or_init(|| Mutex::new(None))
}

fn to_c_string(value: String) -> *mut c_char {
    match CString::new(value) {
        Ok(s) => s.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

fn json_escape(value: &str) -> String {
    value.replace('\\', "\\\\").replace('"', "\\\"")
}

/// Bind the embedded FIPS endpoint and stand up QUIC over it.
///
/// Returns 0 on success, negative on failure.
#[no_mangle]
pub extern "C" fn FipsBridgeStart() -> c_int {
    std::panic::catch_unwind(|| {
        let mut guard = slot().lock().unwrap();
        if guard.is_some() {
            return 0; // already running; idempotent
        }

        let runtime = match tokio::runtime::Builder::new_multi_thread()
            // Small pool: this is I/O-bound, and it shares a process with the
            // Go runtime in the real app.
            .worker_threads(2)
            .thread_name("fips-bridge")
            .enable_all()
            .build()
        {
            Ok(rt) => rt,
            Err(_) => return -1,
        };

        let result = runtime.block_on(async {
            let endpoint = bind_endpoint(EndpointOptions::ephemeral(SCOPE)).await?;
            let npub = endpoint.npub().to_string();
            let address = endpoint.address().to_ipv6().to_string();
            let quic = Arc::new(FipsQuic::new(endpoint).await?);
            Ok::<_, anyhow::Error>((quic, npub, address))
        });

        match result {
            Ok((quic, npub, address)) => {
                *guard = Some(Bridge {
                    runtime,
                    quic,
                    npub,
                    address,
                    started: Instant::now(),
                });
                0
            }
            Err(_) => -2,
        }
    })
    .unwrap_or(-99)
}

/// Snapshot of bridge state, as JSON. Caller frees.
///
/// Polled rather than pushed: callbacks from Rust threads would need
/// `@convention(c)` trampolines on Swift and `AttachCurrentThread` on Android.
/// One serialize per second buys us neither.
#[no_mangle]
pub extern "C" fn FipsBridgeStatusJSON() -> *mut c_char {
    std::panic::catch_unwind(|| {
        let guard = slot().lock().unwrap();
        let json = match guard.as_ref() {
            None => r#"{"running":false}"#.to_string(),
            Some(bridge) => format!(
                r#"{{"running":true,"npub":"{}","address":"{}","uptime_s":{}}}"#,
                json_escape(&bridge.npub),
                json_escape(&bridge.address),
                bridge.started.elapsed().as_secs()
            ),
        };
        to_c_string(json)
    })
    .unwrap_or(std::ptr::null_mut())
}

/// Export a local TCP port to the mesh (provider role).
#[no_mangle]
pub extern "C" fn FipsBridgeExport(local_port: u16) -> c_int {
    std::panic::catch_unwind(|| {
        let guard = slot().lock().unwrap();
        let Some(bridge) = guard.as_ref() else {
            return -1;
        };
        let quic = bridge.quic.clone();
        let target = match format!("127.0.0.1:{local_port}").parse() {
            Ok(addr) => addr,
            Err(_) => return -2,
        };
        bridge.runtime.spawn(async move {
            let _ = egress::serve(quic, target).await;
        });
        0
    })
    .unwrap_or(-99)
}

/// Open a loopback listener that proxies to `npub` over the mesh (consumer
/// role). Returns the bound port, or negative on error.
///
/// This is the call that makes `http://127.0.0.1:<port>/...` work for every HTTP
/// client in the process — URLSession, AVURLAsset, AsyncImage — with no
/// interception anywhere.
#[no_mangle]
pub extern "C" fn FipsBridgeIngress(npub: *const c_char) -> c_int {
    std::panic::catch_unwind(|| {
        if npub.is_null() {
            return -1;
        }
        let npub = match unsafe { CStr::from_ptr(npub) }.to_str() {
            Ok(s) => s.trim().to_string(),
            Err(_) => return -2,
        };

        let guard = slot().lock().unwrap();
        let Some(bridge) = guard.as_ref() else {
            return -3;
        };

        let pubkey = match fips_endpoint::decode_npub(&npub) {
            Ok(pk) => pk,
            Err(_) => return -4,
        };
        let peer = PeerIdentity::from_pubkey(pubkey);
        let quic = bridge.quic.clone();

        bridge.runtime.block_on(async move {
            let listener = match TcpListener::bind("127.0.0.1:0").await {
                Ok(l) => l,
                Err(_) => return -5,
            };
            let port = match listener.local_addr() {
                Ok(addr) => addr.port(),
                Err(_) => return -6,
            };
            let ingress = Ingress::new(quic, peer);
            tokio::spawn(async move {
                let _ = ingress.serve(listener).await;
            });
            port as c_int
        })
    })
    .unwrap_or(-99)
}

#[no_mangle]
pub extern "C" fn FipsBridgeStop() {
    let _ = std::panic::catch_unwind(|| {
        if let Some(bridge) = slot().lock().unwrap().take() {
            // Drop with a timeout so a wedged task cannot block app termination.
            bridge.runtime.shutdown_timeout(std::time::Duration::from_secs(2));
        }
    });
}

/// Free a string returned by this library.
///
/// # Safety
/// `ptr` must be a pointer previously returned by this library, and must not be
/// used afterwards.
#[no_mangle]
pub unsafe extern "C" fn FipsBridgeFreeString(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(unsafe { CString::from_raw(ptr) });
    }
}
