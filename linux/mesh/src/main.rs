//! nv-mesh: the FIPS mesh for Nostr Vault on Linux.
//!
//! The engine the Mac app runs (fips-v2-android, `nvfips`), started with the
//! Mac's options (MeshDevices.swift `macEngineOptions`), as its own process in
//! the nostr-vault-linux container next to havend:
//!
//! - The owner's devices (`$NV_DATA_DIR/mesh-devices.json`) reach havend's
//!   port (`NV_PORT`) uncapped. Only they get answers to traversal offers, so
//!   only they learn this box's LAN or public address.
//! - Everyone else comes in through the public seeds, capped, to havend's
//!   mesh door (`NV_MESH_DOOR_PORT`, havend's `HAVEN_MESH_PLAIN_PORT`), never
//!   to `NV_PORT`.
//! - With no devices listed the engine does not start: an empty list would
//!   be open to anyone.
//!
//! The box's mesh key is its own, made here on first boot
//! (`$NV_DATA_DIR/mesh/key/nsec`: dir 0700, file 0600, this uid's), never the
//! owner's. nv-mesh runs as its own uid, never root or havend's. Its npub is in
//! `mesh/npub` for the owner to add under My Devices; `mesh/status.json` is
//! what havend reports as `mesh` in `/api/box/status`.

use std::fs;
use std::io::{ErrorKind, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use fips::identity::{Identity, PeerIdentity, decode_nsec};
use nvfips::StartOptions;
use serde_json::{Value, json};

/// MeshDevices.swift `defaultFinderRelays`: where the Mac's engine finds and
/// signals its devices, so a phone finds the box the same way.
const FINDER_RELAYS: [&str; 3] = ["wss://relay.nostr.net", "wss://nostr.bitcoiner.social", "wss://relay.btcforplebs.com"];
/// How often mesh-devices.json is re-read and status.json written (the Mac app
/// polls status every 5 s too).
const TICK: Duration = Duration::from_secs(5);
/// Wait before trying a failed start again.
const RETRY: Duration = Duration::from_secs(30);

struct Settings {
    dir: PathBuf,
    /// The owner's devices; written by havend, only read here.
    devices: PathBuf,
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
    // Outside mesh/, which is this uid's: havend runs as another uid and must
    // be able to write it, but never read mesh/key.
    let devices = std::env::var("NV_MESH_DEVICES")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| Path::new(&data).join("mesh-devices.json"));
    Ok(Settings { dir: Path::new(&data).join("mesh"), devices, relay_port, door_port, udp_port, relays })
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

fn euid() -> u32 {
    // SAFETY: geteuid has no preconditions and cannot fail.
    unsafe { libc::geteuid() }
}

/// Fsync a directory, so a rename or link in it survives a power cut.
fn sync_dir(dir: &Path) -> std::io::Result<()> {
    fs::File::open(dir)?.sync_all()
}

/// `path` must be ours with no group or other bits beyond `mode`; a wrong
/// mode is fixed and checked again. Anything we can't make so is an error:
/// the key must never be used from a file someone else can read or swap.
fn ensure_private(path: &Path, mode: u32) -> Result<(), String> {
    let me = euid();
    let check = || -> Result<bool, String> {
        let m = fs::symlink_metadata(path).map_err(|e| format!("{}: {e}", path.display()))?;
        if m.file_type().is_symlink() {
            return Err(format!("{} is a symlink", path.display()));
        }
        if m.uid() != me {
            return Err(format!("{} is owned by uid {}, not this process ({me})", path.display(), m.uid()));
        }
        Ok(m.permissions().mode() & 0o777 & !mode == 0)
    };
    if check()? {
        return Ok(());
    }
    fs::set_permissions(path, fs::Permissions::from_mode(mode)).map_err(|e| format!("{}: chmod: {e}", path.display()))?;
    if check()? { Ok(()) } else { Err(format!("{} is still readable by others after chmod", path.display())) }
}

/// The box's mesh key (`mesh/key/nsec`), made on first boot. Only a key that
/// is not there is made: one that can't be read, doesn't decode, or isn't
/// private to this uid stops the process, since a new key would change the
/// npub every device dials.
fn mesh_nsec(mesh_dir: &Path) -> Result<String, String> {
    let dir = mesh_dir.join("key");
    match fs::create_dir(&dir) {
        Ok(()) => sync_dir(mesh_dir).map_err(|e| format!("{}: {e}", mesh_dir.display()))?,
        Err(e) if e.kind() == ErrorKind::AlreadyExists => {}
        Err(e) => return Err(format!("{}: {e}", dir.display())),
    }
    ensure_private(&dir, 0o700)?;
    let path = dir.join("nsec");
    let read = |path: &Path| -> Result<String, String> {
        ensure_private(path, 0o600)?;
        let nsec = fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?.trim().to_string();
        decode_nsec(&nsec).map_err(|_| format!("{} is not an nsec; move it away to make a new key", path.display()))?;
        Ok(nsec)
    };
    match fs::symlink_metadata(&path) {
        Ok(_) => return read(&path),
        Err(e) if e.kind() == ErrorKind::NotFound => {}
        Err(e) => return Err(format!("{}: {e}", path.display())),
    }
    // First boot. Written to a temp file, then linked into place: a link never
    // replaces an existing file, so of two racing starts one key wins and the
    // other reads it. Then the directory is synced, so the key survives a
    // power cut and the next boot does not quietly make a new npub.
    let nsec = nvfips::generate_nsec();
    // Unique per start and thread, so racing starts never share a temp file.
    static SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.subsec_nanos());
    let seq = SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let tmp = dir.join(format!("nsec.{}.{seq}.{nanos}.tmp", std::process::id()));
    let made = (|| -> std::io::Result<bool> {
        let mut f = fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&tmp)?;
        f.write_all(format!("{nsec}\n").as_bytes())?;
        f.sync_all()?;
        let linked = match fs::hard_link(&tmp, &path) {
            Ok(()) => true,
            Err(e) if e.kind() == ErrorKind::AlreadyExists => false,
            Err(e) => return Err(e),
        };
        Ok(linked)
    })();
    let _ = fs::remove_file(&tmp);
    let made = made.map_err(|e| format!("{}: {e}", path.display()))?;
    sync_dir(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    if !made {
        return read(&path);
    }
    tracing::info!("made this box's mesh key");
    read(&path)
}

fn npub_of(nsec: &str) -> Result<String, String> {
    let sk = decode_nsec(nsec).map_err(|e| format!("nsec: {e}"))?;
    Ok(Identity::from_secret_key(sk).npub())
}

/// The owner's devices from mesh-devices.json: `["npub1…"]`,
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
            tracing::warn!("mesh-devices.json: skipping an entry with no npub");
            continue;
        };
        match PeerIdentity::from_npub(text.trim()) {
            Ok(id) => {
                let npub = id.npub();
                if npub != me && !out.contains(&npub) {
                    out.push(npub);
                }
            }
            Err(_) => tracing::warn!("mesh-devices.json: skipping {text:?}, not an npub"),
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
    // havend faces the internet and shares the data dir: as the same uid it
    // could read the key. nv-mesh needs no root (the TUN is in-process).
    if euid() == 0 {
        return Err("refusing to run as root: run nv-mesh as its own uid, not havend's".into());
    }
    fs::create_dir_all(&s.dir).map_err(|e| format!("{}: {e}", s.dir.display()))?;
    ensure_private(&s.dir, 0o755)?;
    let nsec = mesh_nsec(&s.dir)?;
    let npub = npub_of(&nsec)?;
    write_atomic(&s.dir.join("npub"), format!("{npub}\n").as_bytes(), 0o644).map_err(|e| format!("npub: {e}"))?;
    tracing::info!(%npub, "box mesh npub");

    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().map_err(|e| e.to_string())?;
    rt.block_on(async {
        let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).map_err(|e| e.to_string())?;
        let devices_path = s.devices.clone();
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

#[cfg(test)]
mod tests {
    use super::*;

    fn tmpdir(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("nv-mesh-test-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    fn mode(p: &Path) -> u32 {
        fs::metadata(p).unwrap().permissions().mode() & 0o777
    }

    #[test]
    fn first_boot_makes_a_private_key_and_keeps_it() {
        let d = tmpdir("first");
        let a = mesh_nsec(&d).unwrap();
        assert_eq!(mode(&d.join("key")), 0o700);
        assert_eq!(mode(&d.join("key/nsec")), 0o600);
        assert_eq!(mesh_nsec(&d).unwrap(), a);
        // No temp file left behind.
        assert_eq!(fs::read_dir(d.join("key")).unwrap().count(), 1);
        fs::remove_dir_all(&d).unwrap();
    }

    #[test]
    fn racing_first_boots_agree_on_one_key() {
        let d = tmpdir("race");
        let keys: Vec<String> = (0..8)
            .map(|_| {
                let d = d.clone();
                std::thread::spawn(move || mesh_nsec(&d).unwrap())
            })
            .collect::<Vec<_>>()
            .into_iter()
            .map(|t| t.join().unwrap())
            .collect();
        assert!(keys.iter().all(|k| k == &keys[0]));
        fs::remove_dir_all(&d).unwrap();
    }

    #[test]
    fn a_readable_key_is_made_private() {
        let d = tmpdir("chmod");
        let a = mesh_nsec(&d).unwrap();
        fs::set_permissions(d.join("key/nsec"), fs::Permissions::from_mode(0o644)).unwrap();
        fs::set_permissions(d.join("key"), fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(mesh_nsec(&d).unwrap(), a);
        assert_eq!(mode(&d.join("key/nsec")), 0o600);
        assert_eq!(mode(&d.join("key")), 0o700);
        fs::remove_dir_all(&d).unwrap();
    }

    #[test]
    fn a_key_that_is_not_an_nsec_is_never_replaced() {
        let d = tmpdir("bad");
        mesh_nsec(&d).unwrap();
        fs::write(d.join("key/nsec"), "garbage\n").unwrap();
        assert!(mesh_nsec(&d).is_err());
        assert_eq!(fs::read_to_string(d.join("key/nsec")).unwrap(), "garbage\n");
        fs::remove_dir_all(&d).unwrap();
    }

    #[test]
    fn a_symlinked_key_is_refused() {
        let d = tmpdir("link");
        let a = mesh_nsec(&d).unwrap();
        let elsewhere = d.join("elsewhere");
        fs::write(&elsewhere, format!("{a}\n")).unwrap();
        fs::set_permissions(&elsewhere, fs::Permissions::from_mode(0o600)).unwrap();
        fs::remove_file(d.join("key/nsec")).unwrap();
        std::os::unix::fs::symlink(&elsewhere, d.join("key/nsec")).unwrap();
        assert!(mesh_nsec(&d).is_err());
        fs::remove_dir_all(&d).unwrap();
    }

    /// A key owned by another uid is refused even though root could read it.
    /// Runs only as root (the docker test stage), which can chown.
    #[test]
    fn a_key_owned_by_someone_else_is_refused() {
        if euid() != 0 {
            return;
        }
        let d = tmpdir("owner");
        mesh_nsec(&d).unwrap();
        std::os::unix::fs::chown(d.join("key/nsec"), Some(4242), None).unwrap();
        let err = mesh_nsec(&d).unwrap_err();
        assert!(err.contains("owned by uid 4242"), "{err}");
        fs::remove_dir_all(&d).unwrap();
    }

    /// The reviewer's case: chmod fails, so a 0644 key must not be used.
    #[cfg(target_os = "macos")]
    #[test]
    fn a_key_that_cannot_be_made_private_is_refused() {
        let d = tmpdir("uchg");
        mesh_nsec(&d).unwrap();
        let key = d.join("key/nsec");
        fs::set_permissions(&key, fs::Permissions::from_mode(0o644)).unwrap();
        assert!(std::process::Command::new("chflags").arg("uchg").arg(&key).status().unwrap().success());
        let res = mesh_nsec(&d);
        let _ = std::process::Command::new("chflags").arg("nouchg").arg(&key).status();
        assert!(res.unwrap_err().contains("chmod"));
        fs::remove_dir_all(&d).unwrap();
    }

    #[test]
    fn devices_are_parsed_and_own_npub_dropped() {
        let d = tmpdir("dev");
        let me = npub_of(&nvfips::generate_nsec()).unwrap();
        let other = npub_of(&nvfips::generate_nsec()).unwrap();
        let p = d.join("mesh-devices.json");
        assert!(read_devices(&p, &me).unwrap().is_empty());
        fs::write(&p, format!(r#"[{{"npub":"{other}","name":"phone"}},"{me}","npub1nope","{other}"]"#)).unwrap();
        assert_eq!(read_devices(&p, &me).unwrap(), vec![other.clone()]);
        fs::write(&p, format!(r#"{{"devices":["{other}"]}}"#)).unwrap();
        assert_eq!(read_devices(&p, &me).unwrap(), vec![other]);
        fs::remove_dir_all(&d).unwrap();
    }
}
