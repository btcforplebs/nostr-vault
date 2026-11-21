//! The box dials out: havend's engine reaches the owner's other vaults
//! through nv-mesh.
//!
//! The box's mesh key is nv-mesh's alone (README, "Files and uids"), so havend
//! can neither open a mesh session nor sign as this device. It asks nv-mesh
//! instead, over a Unix socket (`mesh/dial.sock`), one JSON line each way:
//!
//! - `{"op":"dial","npub":"npub1…"}` → `{"ok":true,"base":"http://127.0.0.1:<port>/<token>"}`:
//!   the loopback base whose requests reach that vault's own-device port over
//!   the mesh (`nvfips::ingress`, what the Mac and the phones use). Never
//!   logged: the path holds the ingress token.
//! - `{"op":"sign_copy_start","npub":"npub1…","base":"http://127.0.0.1:<port>/…"}`
//!   → `{"ok":true,"auth":"<base64 kind 27235>"}`: the start proof of a copy
//!   from that vault (docs/MESH_COPY_V2_CONTRACT.md §2), signed by **the box's
//!   mesh key**, never an account key. nv-mesh builds the whole event itself
//!   (`u` = the base's `/copy/v2/start`, `method` POST, `p` = that vault,
//!   now): the socket cannot get anything else signed.
//!
//! Both answer only for the owner's devices nv-mesh runs with (its current
//! `mesh-devices.json` list): the box reaches *your* vaults, nobody else's.
//! Only havend's uid (`NV_MESH_DIAL_UID`, default 10002, the container's and
//! the .deb's "vault") and nv-mesh's own may use the socket; the kernel
//! names the caller (SO_PEERCRED), so the socket's 0666 mode only lets them
//! connect.

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::fs::{FileTypeExt, PermissionsExt};
use std::os::unix::io::AsRawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use base64::Engine as _;
use nostr::{EventBuilder, Keys, Kind, Tag, TagKind, Timestamp};
use serde_json::{Value, json};

/// The socket's name in `mesh/`.
pub const SOCKET: &str = "dial.sock";
/// havend's uid in the container and the .deb (linux/supervise.sh, native/).
const DEFAULT_CLIENT_UID: u32 = 10002;
/// A request is one short line.
const MAX_REQUEST: u64 = 4096;
/// A dial waits up to 10 s for the node (`nvfips::ingress`); then some slack.
const IO_TIMEOUT: Duration = Duration::from_secs(15);
/// Asks served at once; more are turned away rather than queued.
const MAX_IN_FLIGHT: usize = 4;

/// How a vault is reached: `nvfips::ingress`, or a fake in tests.
pub type Ingress = Box<dyn Fn(&str) -> Result<String, i32> + Send + Sync>;

/// What the socket may do: who may ask, for which vaults, as which key.
pub struct Dialer {
    keys: Keys,
    /// The owner's devices the engine runs with now; empty while it is not
    /// running (main keeps it current).
    devices: Arc<Mutex<Vec<String>>>,
    allowed_uids: Vec<u32>,
    in_flight: AtomicUsize,
    ingress: Ingress,
}

/// NV_MESH_DIAL_UID: havend's uid; unset is 10002.
pub fn client_uid_env() -> Result<u32, String> {
    match std::env::var("NV_MESH_DIAL_UID") {
        Err(_) => Ok(DEFAULT_CLIENT_UID),
        Ok(v) if v.trim().is_empty() => Ok(DEFAULT_CLIENT_UID),
        Ok(v) => v.trim().parse().map_err(|_| format!("NV_MESH_DIAL_UID={v:?} is not a uid")),
    }
}

impl Dialer {
    pub fn new(
        nsec: &str,
        devices: Arc<Mutex<Vec<String>>>,
        client_uid: u32,
        ingress: Ingress,
    ) -> Result<Self, String> {
        let keys = Keys::parse(nsec).map_err(|e| format!("mesh key: {e}"))?;
        // nv-mesh's own uid too: when not run as root both share one uid
        // (supervise.sh says so), and then havend can read the key anyway.
        let me = crate::euid();
        let mut allowed_uids = vec![client_uid];
        if me != client_uid {
            allowed_uids.push(me);
        }
        Ok(Dialer { keys, devices, allowed_uids, in_flight: AtomicUsize::new(0), ingress })
    }

    /// Serve `mesh/dial.sock` on its own threads for the life of the process.
    pub fn serve(self: Arc<Self>, mesh_dir: &Path) -> Result<PathBuf, String> {
        let path = mesh_dir.join(SOCKET);
        // A socket left by an earlier run is ours to replace; anything else
        // at that name is not touched.
        match std::fs::symlink_metadata(&path) {
            Ok(m) if m.file_type().is_socket() => {
                std::fs::remove_file(&path).map_err(|e| format!("{}: {e}", path.display()))?;
            }
            Ok(_) => return Err(format!("{} exists and is not a socket", path.display())),
            Err(_) => {}
        }
        let listener = UnixListener::bind(&path).map_err(|e| format!("{}: {e}", path.display()))?;
        // Anyone may connect; only allowed_uids get an answer (peer_uid).
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o666))
            .map_err(|e| format!("{}: chmod: {e}", path.display()))?;
        std::thread::Builder::new()
            .name("nv-mesh-dial".into())
            .spawn(move || {
                for conn in listener.incoming() {
                    let Ok(conn) = conn else { continue };
                    if self.in_flight.fetch_add(1, Ordering::SeqCst) >= MAX_IN_FLIGHT {
                        self.in_flight.fetch_sub(1, Ordering::SeqCst);
                        let _ = reply(&conn, &refuse("busy, try again"));
                        continue;
                    }
                    let me = Arc::clone(&self);
                    let spawned = std::thread::Builder::new().name("nv-mesh-dial-conn".into()).spawn(move || {
                        me.serve_conn(conn);
                        me.in_flight.fetch_sub(1, Ordering::SeqCst);
                    });
                    if spawned.is_err() {
                        self.in_flight.fetch_sub(1, Ordering::SeqCst);
                    }
                }
            })
            .map_err(|e| format!("dial thread: {e}"))?;
        Ok(path)
    }

    fn serve_conn(&self, conn: UnixStream) {
        let _ = conn.set_read_timeout(Some(IO_TIMEOUT));
        let _ = conn.set_write_timeout(Some(IO_TIMEOUT));
        let answer = match peer_uid(&conn) {
            Ok(uid) if self.allowed_uids.contains(&uid) => {
                let mut line = String::new();
                match BufReader::new((&conn).take(MAX_REQUEST)).read_line(&mut line) {
                    Ok(_) => self.answer(&line),
                    Err(_) => refuse("no request"),
                }
            }
            Ok(uid) => {
                tracing::warn!(uid, "dial socket: refused a caller that is not havend");
                refuse("not allowed")
            }
            Err(e) => refuse(&format!("caller unknown: {e}")),
        };
        let _ = reply(&conn, &answer);
    }

    /// One request line → one answer.
    pub fn answer(&self, line: &str) -> Value {
        let req: Value = match serde_json::from_str(line.trim()) {
            Ok(v) => v,
            Err(_) => return refuse("request is not JSON"),
        };
        let Some(npub) = req.get("npub").and_then(Value::as_str).map(str::trim) else {
            return refuse("no npub");
        };
        // Only the owner's devices the engine runs with: the box reaches your
        // vaults, no one else's. Compared re-encoded, as main reads them.
        let npub = match fips::identity::PeerIdentity::from_npub(npub) {
            Ok(id) => id.npub(),
            Err(_) => return refuse("not an npub"),
        };
        if !self.devices.lock().map(|d| d.contains(&npub)).unwrap_or(false) {
            return refuse("not one of the owner's devices on this box's mesh");
        }
        match req.get("op").and_then(Value::as_str) {
            Some("dial") => match (self.ingress)(&npub) {
                Ok(base) => json!({"ok": true, "base": base}),
                Err(rc) => refuse(&format!("could not reach it over the mesh ({rc})")),
            },
            Some("sign_copy_start") => {
                let Some(base) = req.get("base").and_then(Value::as_str) else { return refuse("no base") };
                match self.copy_start_auth(&npub, base) {
                    Ok(auth) => json!({"ok": true, "auth": auth}),
                    Err(e) => refuse(&e),
                }
            }
            _ => refuse("unknown op"),
        }
    }

    /// Base64 of the kind 27235 for POST <base>/copy/v2/start, `p` = the
    /// vault asked (MeshKeyAuth.copyStartTags), signed by the box's mesh key.
    fn copy_start_auth(&self, npub: &str, base: &str) -> Result<String, String> {
        let u = start_url(base)?;
        let tags = [
            Tag::custom(TagKind::custom("u"), [u]),
            Tag::custom(TagKind::custom("method"), ["POST"]),
            Tag::custom(TagKind::custom("p"), [npub.to_string()]),
        ];
        let ev = EventBuilder::new(Kind::HttpAuth, "")
            .tags(tags)
            .custom_created_at(Timestamp::now())
            .sign_with_keys(&self.keys)
            .map_err(|e| format!("signing: {e}"))?;
        Ok(base64::engine::general_purpose::STANDARD.encode(serde_json::to_vec(&ev).map_err(|e| e.to_string())?))
    }
}

/// `http://127.0.0.1:<port>/copy/v2/start` from an ingress base
/// (MeshCopyV2.startURL). Only a loopback http base: an ingress base is
/// always one, so anything else is not what this socket signs for.
fn start_url(base: &str) -> Result<String, String> {
    let rest = base.strip_prefix("http://").ok_or("base is not a loopback http URL")?;
    let host_port = rest.split('/').next().unwrap_or_default();
    let (host, port) = host_port.rsplit_once(':').ok_or("base has no port")?;
    let port: u16 = port.parse().map_err(|_| "base has no port")?;
    if host != "127.0.0.1" || port == 0 {
        return Err("base is not a loopback http URL".into());
    }
    Ok(format!("http://127.0.0.1:{port}/copy/v2/start"))
}

fn refuse(why: &str) -> Value {
    json!({"ok": false, "error": why})
}

fn reply(mut conn: &UnixStream, v: &Value) -> std::io::Result<()> {
    let mut body = serde_json::to_vec(v).unwrap_or_default();
    body.push(b'\n');
    conn.write_all(&body)
}

/// The uid of the process on the other end, as the kernel saw it connect.
#[cfg(target_os = "linux")]
fn peer_uid(conn: &UnixStream) -> std::io::Result<u32> {
    let mut cred = libc::ucred { pid: 0, uid: 0, gid: 0 };
    let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    // SAFETY: cred and len are valid for writes of the sizes given.
    let rc = unsafe {
        libc::getsockopt(
            conn.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut cred as *mut libc::ucred).cast(),
            &mut len,
        )
    };
    if rc != 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(cred.uid)
}

/// The uid of the process on the other end (macOS, for tests on a Mac).
#[cfg(not(target_os = "linux"))]
fn peer_uid(conn: &UnixStream) -> std::io::Result<u32> {
    let (mut uid, mut gid) = (0, 0);
    // SAFETY: uid and gid are valid for writes.
    if unsafe { libc::getpeereid(conn.as_raw_fd(), &mut uid, &mut gid) } != 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(uid)
}

#[cfg(test)]
mod tests {
    use super::*;
    use nostr::JsonUtil;

    fn npub() -> (String, String) {
        let nsec = nvfips::generate_nsec();
        (crate::npub_of(&nsec).unwrap(), nsec)
    }

    fn dialer(devices: Vec<String>, client_uid: u32) -> (Dialer, String) {
        let (box_npub, nsec) = npub();
        let d = Dialer::new(
            &nsec,
            Arc::new(Mutex::new(devices)),
            client_uid,
            Box::new(|n: &str| Ok(format!("http://127.0.0.1:4242/tok-{}", &n[5..9]))),
        )
        .unwrap();
        (d, box_npub)
    }

    #[test]
    fn dial_only_the_owners_devices() {
        let (phone, _) = npub();
        let (stranger, _) = npub();
        let (d, _) = dialer(vec![phone.clone()], 10002);
        let ok = d.answer(&json!({"op": "dial", "npub": phone}).to_string());
        assert_eq!(ok["ok"], true, "{ok}");
        assert!(ok["base"].as_str().unwrap().starts_with("http://127.0.0.1:4242/"));
        let no = d.answer(&json!({"op": "dial", "npub": stranger}).to_string());
        assert_eq!(no["ok"], false);
        // Engine not running: main empties the list, nothing is dialed.
        d.devices.lock().unwrap().clear();
        assert_eq!(d.answer(&json!({"op": "dial", "npub": phone}).to_string())["ok"], false);
    }

    #[test]
    fn copy_start_is_signed_by_the_box_for_one_vault() {
        let (mac, _) = npub();
        let (stranger, _) = npub();
        let (d, box_npub) = dialer(vec![mac.clone()], 10002);
        let a = d.answer(
            &json!({"op": "sign_copy_start", "npub": mac, "base": "http://127.0.0.1:4242/secret-token"}).to_string(),
        );
        assert_eq!(a["ok"], true, "{a}");
        let raw = base64::engine::general_purpose::STANDARD.decode(a["auth"].as_str().unwrap()).unwrap();
        let ev = nostr::Event::from_json(raw).unwrap();
        ev.verify().unwrap();
        assert_eq!(ev.kind, Kind::HttpAuth);
        assert_eq!(nostr::ToBech32::to_bech32(&ev.pubkey).unwrap(), box_npub, "signed by the box's mesh key");
        let tag = |k: &str| ev.tags.iter().find(|t| t.kind().to_string() == k).and_then(|t| t.content()).map(str::to_owned);
        assert_eq!(tag("u").unwrap(), "http://127.0.0.1:4242/copy/v2/start", "token never in the proof");
        assert_eq!(tag("method").unwrap(), "POST");
        assert_eq!(tag("p").unwrap(), mac);
        assert!(ev.content.is_empty());
        // Not for a stranger, and not for a base that is not loopback.
        let s = d.answer(&json!({"op": "sign_copy_start", "npub": stranger, "base": "http://127.0.0.1:1/"}).to_string());
        assert_eq!(s["ok"], false);
        for base in ["https://127.0.0.1:4242/", "http://evil.example:80/", "http://127.0.0.1/", "http://127.0.0.1:0/"] {
            let r = d.answer(&json!({"op": "sign_copy_start", "npub": mac, "base": base}).to_string());
            assert_eq!(r["ok"], false, "{base}");
        }
        // Nothing else gets signed.
        assert_eq!(d.answer(&json!({"op": "sign", "npub": mac, "event": {}}).to_string())["ok"], false);
    }

    #[test]
    fn the_socket_answers_allowed_uids_only() {
        let dir = std::env::temp_dir().join(format!("nv-mesh-dial-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let (phone, _) = npub();
        let ask = |path: &Path| -> Value {
            let mut c = UnixStream::connect(path).unwrap();
            c.write_all(format!("{}\n", json!({"op": "dial", "npub": phone})).as_bytes()).unwrap();
            let mut line = String::new();
            BufReader::new(c).read_line(&mut line).unwrap();
            serde_json::from_str(&line).unwrap()
        };
        // This test's uid is nv-mesh's own: allowed.
        let (d, _) = dialer(vec![phone.clone()], 10002);
        let path = Arc::new(d).serve(&dir).unwrap();
        assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o666);
        assert_eq!(ask(&path)["ok"], true);
        // A caller that is neither: build the same dialer with the list
        // emptied of our uid, then ask.
        let (mut d, _) = dialer(vec![phone.clone()], 10002);
        d.allowed_uids = vec![10002];
        let sub = dir.join("other");
        std::fs::create_dir_all(&sub).unwrap();
        let path = Arc::new(d).serve(&sub).unwrap();
        let r = ask(&path);
        assert_eq!(r["ok"], false);
        assert_eq!(r["error"], "not allowed");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_file_in_the_sockets_place_is_left_alone() {
        let dir = std::env::temp_dir().join(format!("nv-mesh-dial-file-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join(SOCKET), "keep").unwrap();
        let (d, _) = dialer(vec![], 10002);
        assert!(Arc::new(d).serve(&dir).is_err());
        assert_eq!(std::fs::read_to_string(dir.join(SOCKET)).unwrap(), "keep");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
