//! nv-mesh: the FIPS mesh for Nostr Vault on Linux.
//!
//! The engine the Mac app runs (fips-v2-android, `nvfips`), started with the
//! Mac's options (MeshDevices.swift `macEngineOptions`), as its own process in
//! the nostr-vault-linux container next to havend:
//!
//! - The owner's devices (`$NV_DATA_DIR/mesh/devices.json`) reach havend's
//!   port (`NV_PORT`) uncapped. Only they get answers to traversal offers, so
//!   only they learn this box's LAN or public address.
//! - Everyone else comes in through the public seeds, capped, to havend's
//!   mesh door (`NV_MESH_DOOR_PORT`, havend's `HAVEN_MESH_PLAIN_PORT`), never
//!   to `NV_PORT`.
//! - With no devices listed the engine does not start: an empty list would
//!   be open to anyone.
//!
//! The box's mesh key is its own, made here on first boot
//! (`$NV_DATA_DIR/mesh/nsec`, mode 0600), never the owner's. Its npub is in
//! `mesh/npub` for the owner to add under My Devices; `mesh/status.json` is
//! what havend reports as `mesh` in `/api/box/status`.

use std::fs;
use std::io::{ErrorKind, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use fips::identity::{Identity, PeerIdentity, decode_nsec};
use nvfips::StartOptions;
use serde_json::{Value, json};

/// MeshDevices.swift `defaultFinderRelays`: where the Mac's engine finds and
/// signals its devices, so a phone finds the box the same way.
const FINDER_RELAYS: [&str; 3] = ["wss://relay.nostr.net", "wss://nostr.bitcoiner.social", "wss://relay.btcforplebs.com"];
/// How often devices.json is re-read and status.json written (the Mac app
/// polls status every 5 s too).
const TICK: Duration = Duration::from_secs(5);
/// Wait before trying a failed start again.
const RETRY: Duration = Duration::from_secs(30);

struct Settings {
    dir: PathBuf,
    relay_port: u16,
    door_port: u16,
    udp_port: u16,
    relays: Vec<String>,
}

fn port_env(name: &str, default: u16) -> Result<u16, String> {
    match std::env::var(name) {
        Err(_) => Ok(default),
        Ok(v) if v.trim().is_empty() => Ok(default),
        Ok(v) => v.trim().parse().map_err(|_| format!("{name}={v:?} is not a port")),
    }
}

fn settings() -> Result<Settings, String> {
    let data = std::env::var("NV_DATA_DIR").ok().filter(|s| !s.trim().is_empty()).unwrap_or_else(|| "/data".into());
    let relay_port = port_env("NV_PORT", 8080)?;
    // Mac: meshPlainPort = relayPort + 1.
    let door_port = port_env("NV_MESH_DOOR_PORT", relay_port.checked_add(1).ok_or("NV_PORT too high")?)?;
    let udp_port = port_env("NV_MESH_UDP_PORT", 0)?;
    if relay_port == 0 || door_port == 0 || door_port == relay_port {
        return Err("NV_PORT and NV_MESH_DOOR_PORT must be two different ports".into());
    }
    let relays: Vec<String> = std::env::var("NV_MESH_RELAYS")
        .unwrap_or_default()
        .split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
        .collect();
    let relays = if relays.is_empty() { FINDER_RELAYS.iter().map(|s| s.to_string()).collect() } else { relays };
    Ok(Settings { dir: Path::new(&data).join("mesh"), relay_port, door_port, udp_port, relays })
}

/// Write `contents` to `path` through a temp file and rename, so a reader
/// never sees half a file.
fn write_atomic(path: &Path, contents: &[u8], mode: u32) -> std::io::Result<()> {
    let tmp = path.with_extension("tmp");
    let _ = fs::remove_file(&tmp);
    let mut f = fs::OpenOptions::new().write(true).create_new(true).mode(mode).open(&tmp)?;
    f.write_all(contents)?;
    f.sync_all()?;
    fs::rename(&tmp, path)
}

/// The box's mesh key, made on first boot. Only a key that is not there is
/// made: one that can't be read or doesn't decode stops the process, since a
/// new key would change the npub every device dials.
fn mesh_nsec(dir: &Path) -> Result<String, String> {
    let path = dir.join("nsec");
    match fs::read_to_string(&path) {
        Ok(s) => {
            let nsec = s.trim().to_string();
            decode_nsec(&nsec).map_err(|_| format!("{} is not an nsec; move it away to make a new key", path.display()))?;
            let mode = fs::metadata(&path).map(|m| m.permissions().mode() & 0o777).unwrap_or(0);
            if mode & 0o077 != 0 {
                let _ = fs::set_permissions(&path, fs::Permissions::from_mode(0o600));
            }
            Ok(nsec)
        }
        Err(e) if e.kind() == ErrorKind::NotFound => {
            let nsec = nvfips::generate_nsec();
            write_atomic(&path, format!("{nsec}\n").as_bytes(), 0o600).map_err(|e| format!("{}: {e}", path.display()))?;
            tracing::info!("made this box's mesh key");
            Ok(nsec)
        }
        Err(e) => Err(format!("{}: {e}", path.display())),
    }
}

fn npub_of(nsec: &str) -> Result<String, String> {
    let sk = decode_nsec(nsec).map_err(|e| format!("nsec: {e}"))?;
    Ok(Identity::from_secret_key(sk).npub())
}

/// The owner's devices from devices.json: `["npub1…"]`,
/// `[{"npub": "npub1…", "name": …}]` or `{"devices": [ … ]}`. No file is no
/// devices. Each npub is decoded and re-encoded; one that does not decode is
/// skipped, and so is this box's own.
fn read_devices(path: &Path, me: &str) -> Result<Vec<String>, String> {
    let raw = match fs::read(path) {
        Ok(raw) => raw,
        Err(e) if e.kind() == ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(format!("{}: {e}", path.display())),
    };
    let value: Value = serde_json::from_slice(&raw).map_err(|e| format!("{}: {e}", path.display()))?;
    let list = match &value {
        Value::Array(list) => list,
        Value::Object(o) => match o.get("devices") {
            Some(Value::Array(list)) => list,
            _ => return Err(format!("{}: no \"devices\" list", path.display())),
        },
        _ => return Err(format!("{}: not a list", path.display())),
    };
    let mut out: Vec<String> = Vec::new();
    for entry in list {
        let Some(text) = entry.as_str().or_else(|| entry.get("npub").and_then(Value::as_str)) else {
            tracing::warn!("devices.json: skipping an entry with no npub");
            continue;
        };
        match PeerIdentity::from_npub(text.trim()) {
            Ok(id) => {
                let npub = id.npub();
                if npub != me && !out.contains(&npub) {
                    out.push(npub);
                }
            }
            Err(_) => tracing::warn!("devices.json: skipping {text:?}, not an npub"),
        }
    }
    Ok(out)
}

/// MeshDevices.swift `macEngineOptions`, plus the UDP port.
fn options(devices: &[String], s: &Settings) -> StartOptions {
    StartOptions {
        own_devices: devices.to_vec(),
        relays: s.relays.clone(),
        public_seeds: true,
        strangers_port: s.door_port,
        read_anyone: true,
        // Answers to the owner's devices carry the LAN address too, so a phone
        // on the same Wi-Fi links without router hairpin. Only they get answers.
        lan: true,
        udp_port: s.udp_port,
        ..StartOptions::default()
    }
}

/// Start the engine for `devices` and share havend on it. Err in plain words.
fn start_engine(nsec: &str, devices: &[String], s: &Settings) -> Result<(), String> {
    nvfips::start(nsec, &options(devices, s)).map_err(|e| format!("mesh did not start: {e:#}"))?;
    match nvfips::export(s.relay_port) {
        0 => {
            tracing::info!(
                devices = devices.len(),
                relay_port = s.relay_port,
                door_port = s.door_port,
                "mesh live: own devices on the relay port, capped strangers on the mesh door"
            );
            Ok(())
        }
        rc => {
            nvfips::stop();
            Err(format!("could not share port {} on the mesh ({rc})", s.relay_port))
        }
    }
}

fn write_status(dir: &Path, npub: &str, devices: usize, error: Option<&str>) {
    let mut status: Value = serde_json::from_str(&nvfips::status_json()).unwrap_or_else(|_| json!({"running": false}));
    if let Value::Object(o) = &mut status {
        o.insert("npub".into(), Value::from(npub));
        o.insert("devices".into(), Value::from(devices));
        o.insert("error".into(), error.map_or(Value::Null, Value::from));
        o.insert("updated".into(), Value::from(unix_now()));
    }
    let body = serde_json::to_vec_pretty(&status).unwrap_or_default();
    if let Err(e) = write_atomic(&dir.join("status.json"), &body, 0o644) {
        tracing::warn!("status.json: {e}");
    }
}

fn unix_now() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs())
}

fn engine_running() -> bool {
    serde_json::from_str::<Value>(&nvfips::status_json())
        .ok()
        .and_then(|v| v.get("running").and_then(Value::as_bool))
        .unwrap_or(false)
}

fn main() {
    nvfips::init_logging();
    if let Err(e) = run() {
        tracing::error!("{e}");
        eprintln!("nv-mesh: {e}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let s = settings()?;
    fs::create_dir_all(&s.dir).map_err(|e| format!("{}: {e}", s.dir.display()))?;
    fs::set_permissions(&s.dir, fs::Permissions::from_mode(0o755)).map_err(|e| format!("{}: {e}", s.dir.display()))?;
    let nsec = mesh_nsec(&s.dir)?;
    let npub = npub_of(&nsec)?;
    write_atomic(&s.dir.join("npub"), format!("{npub}\n").as_bytes(), 0o644).map_err(|e| format!("npub: {e}"))?;
    tracing::info!(%npub, "box mesh npub");

    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().map_err(|e| e.to_string())?;
    rt.block_on(async {
        let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).map_err(|e| e.to_string())?;
        let devices_path = s.dir.join("devices.json");
        // The list the engine runs with; None = not started for any list yet.
        let mut running_for: Option<Vec<String>> = None;
        let mut retry_at: Option<Instant> = None;
        let mut error: Option<String> = None;
        let mut devices: Vec<String> = Vec::new();
        loop {
            match read_devices(&devices_path, &npub) {
                Ok(list) => devices = list,
                // Keep the last good list: a half-edited file must not stop the mesh.
                Err(e) => tracing::warn!("{e}"),
            }
            // A changed list restarts the engine, as on the Mac: a removed
            // device's session drops and its next offer gets no answer. An
            // engine that failed or died is started again after RETRY.
            let changed = running_for.as_ref() != Some(&devices);
            let due = retry_at.is_none_or(|t| Instant::now() >= t);
            if changed || (!devices.is_empty() && !engine_running() && due) {
                nvfips::stop();
                running_for = Some(devices.clone());
                retry_at = None;
                error = None;
                if devices.is_empty() {
                    error = Some(format!(
                        "No devices yet. Add this box ({npub}) under My Devices on your phone, and the phone on the box."
                    ));
                } else if let Err(e) = start_engine(&nsec, &devices, &s) {
                    tracing::warn!("{e}");
                    error = Some(e);
                    retry_at = Some(Instant::now() + RETRY);
                }
            }
            write_status(&s.dir, &npub, devices.len(), error.as_deref());
            tokio::select! {
                _ = tokio::time::sleep(TICK) => {}
                _ = tokio::signal::ctrl_c() => break,
                _ = term.recv() => break,
            }
        }
        tracing::info!("stopping");
        nvfips::stop();
        write_status(&s.dir, &npub, devices.len(), Some("stopped"));
        Ok(())
    })
}
