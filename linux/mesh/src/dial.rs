//! The box dials out: havend's engine reaches the owner's other vaults
//! through nv-mesh.
//!
//! The box's mesh key is nv-mesh's alone (README, "Files and uids"), so havend
//! can neither open a mesh session nor sign as this device. It asks nv-mesh
//! instead, over a Unix socket (`/run/nv-mesh/dial.sock`), one JSON line each way:
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
//!
//! Two more ops serve two-scan pairing (docs/MESH_PAIRING_CONTRACT.md §3), where
//! the other device is, by definition, not paired yet, so these two skip the
//! device check. havend runs the session (haven-go internal/box/pairing_box.go);
//! nv-mesh only does what needs the key:
//!
//! - `{"op":"pair_open","event":{…}}` → `{"ok":true,"sender":"<hex>","content":"…"}`:
//!   one kind-21195 event to this box (`p` = the box's mesh pubkey), signature
//!   checked, content NIP-44 decrypted between the two mesh keys. Nothing else
//!   is decrypted: not another kind, not an event to someone else.
//! - `{"op":"pair_ack","npub":"npub1…","content":"{\"v\":1,\"ack\":true,\"d\":\"<hex>\",\"w\":true}"}`
//!   → `{"ok":true,"event":{…}}`: the ack sealed to that device and signed by
//!   the box's mesh key, as a kind-21195 event with `p` = that device. The
//!   content must be exactly an ack of the contract's shape (the box has no
//!   camera, so always the check-words form, `w` true); anything else is refused,
//!   so this op cannot get a hello, a DM or any other event signed.
//! Only havend's uid and nv-mesh's own may use the socket. havend's uid is
//! looked up by name ("nvvault", the .deb's and the .apk's, then "vault", the
//! container's), never assumed: a package gives nvvault another uid when 10002
//! is a person's. `NV_MESH_DIAL_UID` overrides it; with neither, there is no
//! socket. The kernel names the caller (SO_PEERCRED).
//!
//! Two walls: the socket lives in a private runtime dir (`NV_MESH_RUN_DIR`,
//! default `/run/nv-mesh`, made by root before nv-mesh starts: nv-mesh's,
//! group havend's, 0750), never on the data dir (a host bind mount under
//! Docker), so other local uids can't reach it at all; and the uid check.

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::fs::{FileTypeExt, PermissionsExt};
use std::os::unix::io::AsRawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use base64::Engine as _;
use nostr::nips::nip44;
use nostr::{Event, EventBuilder, FromBech32, JsonUtil, Keys, Kind, PublicKey, Tag, TagKind, Timestamp};
use serde_json::{Value, json};

/// The socket's name in `mesh/`.
pub const SOCKET: &str = "dial.sock";
/// Where the socket lives unless NV_MESH_RUN_DIR says otherwise.
pub const DEFAULT_RUN_DIR: &str = "/run/nv-mesh";
/// havend's user: the .deb's and the .apk's name, then the container's.
const CLIENT_NAMES: [&str; 2] = ["nvvault", "vault"];
/// A request is one short line.
const MAX_REQUEST: u64 = 4096;
/// A dial waits up to 10 s for the node (`nvfips::ingress`); then some slack.
const IO_TIMEOUT: Duration = Duration::from_secs(15);
/// Asks served at once; more are turned away rather than queued.
const MAX_IN_FLIGHT: usize = 4;
/// Two-scan pairing's ephemeral event (docs/MESH_PAIRING_CONTRACT.md §3).
const PAIR_KIND: u16 = 21195;
/// A sealed hello is a few hundred bytes; anything bigger is not one.
const MAX_PAIR_CONTENT: usize = 2048;

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

/// havend's uid: `NV_MESH_DIAL_UID` when set, else the uid of the first of
/// CLIENT_NAMES that exists. None of them is an error: no socket, rather than
/// a guessed uid that may be a person's.
pub fn client_uid(env: Option<String>, lookup: impl Fn(&str) -> Option<u32>) -> Result<u32, String> {
    if let Some(v) = env.filter(|v| !v.trim().is_empty()) {
        return v.trim().parse().map_err(|_| format!("NV_MESH_DIAL_UID={v:?} is not a uid"));
    }
    CLIENT_NAMES
        .iter()
        .find_map(|n| lookup(n))
        .ok_or_else(|| format!("no {} user and no NV_MESH_DIAL_UID: no one to answer", CLIENT_NAMES.join(" or ")))
}

/// client_uid from this process's environment and the passwd database.
pub fn client_uid_here() -> Result<u32, String> {
    client_uid(std::env::var("NV_MESH_DIAL_UID").ok(), passwd_uid)
}

/// The uid of a user by name (getpwnam_r), or None.
fn passwd_uid(name: &str) -> Option<u32> {
    let cname = std::ffi::CString::new(name).ok()?;
    let mut buf = vec![0u8; 16 * 1024];
    // SAFETY: pwd, buf and out are valid for writes of their sizes; pw_uid is
    // read only when getpwnam_r filled pwd (rc 0, out non-null).
    unsafe {
        let mut pwd: libc::passwd = std::mem::zeroed();
        let mut out: *mut libc::passwd = std::ptr::null_mut();
        let rc = libc::getpwnam_r(cname.as_ptr(), &mut pwd, buf.as_mut_ptr().cast(), buf.len(), &mut out);
        (rc == 0 && !out.is_null()).then_some(pwd.pw_uid)
    }
}

/// NV_MESH_RUN_DIR, else /run/nv-mesh.
pub fn run_dir_env() -> PathBuf {
    std::env::var("NV_MESH_RUN_DIR")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(DEFAULT_RUN_DIR))
}

/// The socket's dir must be a real dir of this uid that other uids can't
/// enter (no "other" bits, no group write): root made it (prepare,
/// supervise.sh). nv-mesh never makes or fixes it: it can't give it
/// havend's group, and a dir it made would be open or useless.
pub fn check_run_dir(dir: &Path) -> Result<(), String> {
    use std::os::unix::fs::MetadataExt;
    let m = std::fs::symlink_metadata(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    if !m.file_type().is_dir() {
        return Err(format!("{} is not a folder", dir.display()));
    }
    if m.uid() != crate::euid() {
        return Err(format!("{} belongs to uid {}, not nv-mesh", dir.display(), m.uid()));
    }
    if m.mode() & 0o027 != 0 {
        return Err(format!("{} is mode {:o}; it must be 0750 (others kept out)", dir.display(), m.mode() & 0o777));
    }
    Ok(())
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

    /// Serve `<run dir>/dial.sock` on its own threads for the life of the
    /// process. The caller checks the dir first (check_run_dir).
    pub fn serve(self: Arc<Self>, run_dir: &Path) -> Result<PathBuf, String> {
        let path = run_dir.join(SOCKET);
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
        // The dir keeps other uids out; within it, only allowed_uids get an
        // answer (peer_uid).
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
        // Pairing talks to a device that is not paired yet: no device check.
        match req.get("op").and_then(Value::as_str) {
            Some("pair_open") => {
                return match self.pair_open(req.get("event")) {
                    Ok((sender, content)) => json!({"ok": true, "sender": sender, "content": content}),
                    Err(e) => refuse(&e),
                };
            }
            Some("pair_ack") => {
                let npub = req.get("npub").and_then(Value::as_str).unwrap_or_default();
                let content = req.get("content").and_then(Value::as_str).unwrap_or_default();
                return match self.pair_ack(npub, content) {
                    Ok(ev) => json!({"ok": true, "event": ev}),
                    Err(e) => refuse(&e),
                };
            }
            _ => {}
        }
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

/// A pairing hello or ack to this box: the event's signature checked, `p` =
/// this box, then its content opened between the two mesh keys.
    fn pair_open(&self, ev: Option<&Value>) -> Result<(String, String), String> {
        let ev = ev.ok_or("no event")?;
        let ev = Event::from_json(ev.to_string()).map_err(|_| "not a nostr event".to_string())?;
        if ev.kind != Kind::from(PAIR_KIND) {
            return Err("not a pairing event".into());
        }
        let me = self.keys.public_key();
        let to: Vec<&PublicKey> = ev.tags.public_keys().collect();
        if to.len() != 1 || *to[0] != me {
            return Err("not addressed to this box".into());
        }
        ev.verify().map_err(|_| "bad signature".to_string())?;
        if ev.content.len() > MAX_PAIR_CONTENT {
            return Err("content too long".into());
        }
        let content = nip44::decrypt(self.keys.secret_key(), &ev.pubkey, &ev.content).map_err(|_| "does not decrypt".to_string())?;
        Ok((ev.pubkey.to_hex(), content))
    }

    /// The check-words ack (contract §3) sealed to `npub` and signed by the
    /// box's mesh key. Only that exact shape is sealed and signed.
    fn pair_ack(&self, npub: &str, content: &str) -> Result<Value, String> {
        let to = PublicKey::from_bech32(npub.trim()).map_err(|_| "not an npub".to_string())?;
        if !is_words_ack(content) {
            return Err("not a check-words ack".into());
        }
        let sealed = nip44::encrypt(self.keys.secret_key(), &to, content, nip44::Version::V2).map_err(|e| format!("sealing: {e}"))?;
        let ev = EventBuilder::new(Kind::from(PAIR_KIND), sealed)
            .tags([Tag::public_key(to)])
            .custom_created_at(Timestamp::now())
            .sign_with_keys(&self.keys)
            .map_err(|e| format!("signing: {e}"))?;
        serde_json::to_value(&ev).map_err(|e| e.to_string())
    }
}

/// Exactly `{"v":1,"ack":true,"d":"<64 lower-case hex>","w":true}`: the ack a
/// device with no camera sends (MESH_PAIRING_CONTRACT.md §3). Parsed, not
/// compared as text, so key order is checked by the shape and the digest by
/// its alphabet; nothing else may be in it.
fn is_words_ack(content: &str) -> bool {
    let Ok(Value::Object(o)) = serde_json::from_str::<Value>(content) else { return false };
    if o.len() != 4 || o.get("v") != Some(&json!(1)) || o.get("ack") != Some(&json!(true)) || o.get("w") != Some(&json!(true)) {
        return false;
    }
    matches!(o.get("d").and_then(Value::as_str), Some(d) if d.len() == 64 && d.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)))
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

    /// A device's sealed kind-21195 to `to_hex`, as the phones send it.
    fn sealed(from: &Keys, to: &PublicKey, content: &str, kind: u16) -> Value {
        let sealed = nip44::encrypt(from.secret_key(), to, content, nip44::Version::V2).unwrap();
        let ev = EventBuilder::new(Kind::from(kind), sealed).tags([Tag::public_key(*to)]).sign_with_keys(from).unwrap();
        serde_json::to_value(&ev).unwrap()
    }

    const WORDS_ACK: &str = "{\"v\":1,\"ack\":true,\"d\":\"16330bfcff08bc831fb22950d3942d08fc108565d9e866bd226b505008fb37b7\",\"w\":true}";

    #[test]
    fn pair_open_decrypts_one_hello_to_this_box_and_nothing_else() {
        let (d, box_npub) = dialer(vec![], 10002);
        let me = PublicKey::from_bech32(&box_npub).unwrap();
        let phone = Keys::generate();
        let hello = "{\"v\":1,\"s\":\"MfL-vrRY_QiUhuVK2cwvQQ\",\"n\":\"Logen's iPhone\",\"r\":\"phone\",\"o\":\"npub1emme6lujwlzw6y2afr6teeuhgf7rt3n6yg40aagpyfuhuu06xf9q6z30yj\",\"t\":1793800010}";
        // The phone is not paired (an empty device list): pairing still opens.
        let r = d.answer(&json!({"op": "pair_open", "event": sealed(&phone, &me, hello, 21195)}).to_string());
        assert_eq!(r["ok"], true, "{r}");
        assert_eq!(r["sender"], phone.public_key().to_hex());
        assert_eq!(r["content"], hello);
        // Another kind, an event to someone else, a broken signature, no event.
        let other = Keys::generate();
        for (name, ev) in [
            ("kind", sealed(&phone, &me, hello, 1059)),
            ("to someone else", sealed(&phone, &other.public_key(), hello, 21195)),
            ("bad signature", {
                let mut ev = sealed(&phone, &me, hello, 21195);
                ev["content"] = Value::from(sealed(&phone, &me, "x", 21195)["content"].as_str().unwrap().to_owned());
                ev
            }),
            ("not an event", json!({"kind": 21195})),
        ] {
            let r = d.answer(&json!({"op": "pair_open", "event": ev}).to_string());
            assert_eq!(r["ok"], false, "{name}: {r}");
        }
        assert_eq!(d.answer(&json!({"op": "pair_open"}).to_string())["ok"], false);
    }

    #[test]
    fn pair_ack_seals_and_signs_only_a_check_words_ack() {
        let (d, box_npub) = dialer(vec![], 10002);
        let phone = Keys::generate();
        let phone_npub = nostr::ToBech32::to_bech32(&phone.public_key()).unwrap();
        let r = d.answer(&json!({"op": "pair_ack", "npub": phone_npub, "content": WORDS_ACK}).to_string());
        assert_eq!(r["ok"], true, "{r}");
        let ev = Event::from_json(r["event"].to_string()).unwrap();
        ev.verify().unwrap();
        assert_eq!(ev.kind, Kind::from(21195u16));
        assert_eq!(nostr::ToBech32::to_bech32(&ev.pubkey).unwrap(), box_npub, "signed by the box's mesh key");
        let to: Vec<&PublicKey> = ev.tags.public_keys().collect();
        assert_eq!(to, vec![&phone.public_key()]);
        let opened = nip44::decrypt(phone.secret_key(), &ev.pubkey, &ev.content).unwrap();
        assert_eq!(opened, WORDS_ACK, "the phone reads the ack byte for byte");
        // Nothing but that shape: the scan form (no w), a hello, extra keys,
        // an upper-case or short digest, a bad npub.
        for (name, content) in [
            ("scan form", "{\"v\":1,\"ack\":true,\"d\":\"16330bfcff08bc831fb22950d3942d08fc108565d9e866bd226b505008fb37b7\"}"),
            ("a hello", "{\"v\":1,\"s\":\"MfL-vrRY_QiUhuVK2cwvQQ\",\"r\":\"phone\",\"o\":\"npub1x\",\"t\":1}"),
            ("extra key", "{\"v\":1,\"ack\":true,\"d\":\"16330bfcff08bc831fb22950d3942d08fc108565d9e866bd226b505008fb37b7\",\"w\":true,\"x\":1}"),
            ("upper case", "{\"v\":1,\"ack\":true,\"d\":\"16330BFCFF08BC831FB22950D3942D08FC108565D9E866BD226B505008FB37B7\",\"w\":true}"),
            ("short", "{\"v\":1,\"ack\":true,\"d\":\"1633\",\"w\":true}"),
            ("w false", "{\"v\":1,\"ack\":true,\"d\":\"16330bfcff08bc831fb22950d3942d08fc108565d9e866bd226b505008fb37b7\",\"w\":false}"),
            ("not json", "ack"),
        ] {
            let r = d.answer(&json!({"op": "pair_ack", "npub": phone_npub, "content": content}).to_string());
            assert_eq!(r["ok"], false, "{name}: {r}");
        }
        assert_eq!(d.answer(&json!({"op": "pair_ack", "npub": "npub1nope", "content": WORDS_ACK}).to_string())["ok"], false);
        // The two old ops still need a paired device.
        assert_eq!(d.answer(&json!({"op": "dial", "npub": phone_npub}).to_string())["ok"], false);
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
    fn havends_uid_is_looked_up_by_name() {
        // The .deb on a host where 10002 is a person's: nvvault got 10005.
        let host = |n: &str| match n {
            "nvvault" => Some(10005),
            "alice" => Some(10002),
            _ => None,
        };
        assert_eq!(client_uid(None, host), Ok(10005));
        let (d, _) = dialer(vec![], client_uid(None, host).unwrap());
        assert!(!d.allowed_uids.contains(&10002), "{:?}", d.allowed_uids);
        // The container: only "vault".
        assert_eq!(client_uid(None, |n: &str| (n == "vault").then_some(10002)), Ok(10002));
        // nvvault wins over vault.
        assert_eq!(client_uid(None, |n: &str| Some(if n == "nvvault" { 7 } else { 8 })), Ok(7));
        // An explicit override wins; a blank one is unset.
        assert_eq!(client_uid(Some("4242".into()), host), Ok(4242));
        assert_eq!(client_uid(Some(" ".into()), host), Ok(10005));
        assert!(client_uid(Some("nvvault".into()), host).is_err());
        // Neither name: no uid at all, never a default.
        assert!(client_uid(None, |_: &str| None).is_err());
        // The real lookup reads the passwd database.
        assert_eq!(passwd_uid("root"), Some(0));
        assert_eq!(passwd_uid("no-such-user-nv-mesh"), None);
    }

    #[test]
    fn the_run_dir_must_keep_others_out() {
        let dir = std::env::temp_dir().join(format!("nv-mesh-run-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        for (mode, ok) in [(0o750, true), (0o700, true), (0o755, false), (0o770, false), (0o751, false)] {
            std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(mode)).unwrap();
            assert_eq!(check_run_dir(&dir).is_ok(), ok, "{mode:o}");
        }
        let link = dir.with_extension("link");
        let _ = std::fs::remove_file(&link);
        std::os::unix::fs::symlink(&dir, &link).unwrap();
        assert!(check_run_dir(&link).is_err(), "a symlink is refused");
        assert!(check_run_dir(&dir.join("missing")).is_err());
        let _ = std::fs::remove_file(&link);
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
