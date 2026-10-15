//! The phone side of the browser relay: hand already-signed notes to a
//! `nostrvault.app` relay page over the mesh.
//!
//! The page serves NIP-01 over TCP/FIPS on FSP port 7447 (`web-relay/src/fips`).
//! `web-relay-vault` speaks that protocol over any datagram link; here the link
//! is this node's own datagram API, on a socket inside the app's sandbox. Nothing
//! is signed here: an event leaves exactly as the app passed it, and the page
//! checks the signature and the author before it keeps anything.
//!
//! The page opens the FIPS session, not this side: it dials each vault it is
//! paired with, through the public seeds. A session this node started to the
//! page fails there (see `web-relay/src/fips/node.js`), so `relay_push` waits
//! for the page's session instead of forcing one, retrying until its deadline.

use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail, ensure};
use fips::identity::PeerIdentity;
use serde::Serialize;
use serde_json::Value;
use web_relay_vault::client::run_publish;
use web_relay_vault::native::NativeLink;

use crate::{ERR_BAD_EVENTS, ERR_BAD_NPUB, ERR_NOT_RUNNING, ERR_RELAY_OFF, state};

/// A public seed: the route the browser relay page is on.
pub struct Seed {
    pub npub: &'static str,
    /// `host:port`, UDP.
    pub addr: &'static str,
}

/// The seeds the relay page joins (`web-relay/src/fips/node.js` `PUBLIC_SEEDS` is their
/// WebSocket side). The single definition both apps start with.
pub const PUBLIC_SEEDS: &[Seed] = &[
    Seed { npub: "npub1927ye6w57stma7yntatltdphes2fugdn8ktqdmp72225crrvgwqq4p7rkd", addr: "fips1.iris.to:51820" },
    Seed { npub: "npub1zv3qmj7xz7znehyqwzpc26fcjxtcf7tpxeevxx93ymgm6kw7gjpqp9npvh", addr: "fips2.iris.to:51820" },
];

/// Longest socket path every platform accepts (`sun_path` is 104 bytes on
/// Darwin, 108 on Linux, both including the NUL).
const MAX_SOCKET_PATH: usize = 100;

/// One attempt's share of the deadline: long enough for a page that is up,
/// short enough that a session arriving late still gets a second try.
const ATTEMPT: Duration = Duration::from_secs(15);
/// Pause between attempts while the page has not opened its session yet.
const RETRY_PAUSE: Duration = Duration::from_secs(2);
/// Events per push. The page keeps what it accepts; a long backlog goes in turns.
pub const MAX_EVENTS: usize = 100;

/// One push at a time: a push holds local FSP port 7447 for its stream.
static PUSH: Mutex<()> = Mutex::new(());

/// A seed as a `peers:` entry. Both fields are checked and re-encoded, so no
/// input can add keys to the config.
pub(crate) fn seed_yaml(seed: &Seed) -> Result<String> {
    let npub = PeerIdentity::from_npub(seed.npub).with_context(|| format!("seed {:?}", seed.npub))?.npub();
    let (host, port) = seed.addr.rsplit_once(':').context("seed address needs host:port")?;
    ensure!(
        !host.is_empty() && host.chars().all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-'),
        "seed host {host:?}"
    );
    let port: u16 = port.parse().context("seed port")?;
    Ok(format!(
        "  - npub: \"{npub}\"\n    addresses:\n      - transport: udp\n        addr: \"{host}:{port}\"\n    connect_policy: auto_connect\n"
    ))
}

/// The checked socket path, or `None` for "off".
pub(crate) fn socket_path(raw: &str) -> Result<Option<PathBuf>> {
    if raw.is_empty() {
        return Ok(None);
    }
    let path = Path::new(raw);
    ensure!(path.is_absolute(), "relay socket path must be absolute");
    ensure!(raw.len() <= MAX_SOCKET_PATH, "relay socket path is longer than {MAX_SOCKET_PATH} bytes");
    Ok(Some(path.to_path_buf()))
}

/// The `native_api:` block under `node:`, or nothing when the socket is off.
pub(crate) fn native_api_yaml(raw: &str) -> Result<String> {
    let Some(path) = socket_path(raw)? else { return Ok(String::new()) };
    // A JSON string is a valid YAML scalar, so the path cannot break out.
    let quoted = serde_json::Value::from(path.to_str().context("relay socket path is not UTF-8")?).to_string();
    Ok(format!("  native_api:\n    enabled: true\n    socket_path: {quoted}\n"))
}

/// Signed events, as the app passed them: one object or a list. Only the
/// shape is checked here; the page verifies signatures.
pub(crate) fn parse_events(json: &str) -> Result<Vec<Value>> {
    let events = match serde_json::from_str::<Value>(json).context("events are not JSON")? {
        Value::Array(list) => list,
        one @ Value::Object(_) => vec![one],
        _ => bail!("events must be an object or a list"),
    };
    ensure!(!events.is_empty(), "no events");
    ensure!(events.len() <= MAX_EVENTS, "more than {MAX_EVENTS} events");
    let hex = |v: &Value, len: usize| v.as_str().is_some_and(|s| s.len() == len && s.bytes().all(|b| b.is_ascii_hexdigit()));
    for (i, e) in events.iter().enumerate() {
        ensure!(e.is_object(), "event {i} is not an object");
        ensure!(hex(&e["id"], 64) && hex(&e["pubkey"], 64) && hex(&e["sig"], 128), "event {i} is not signed");
        ensure!(e["kind"].is_u64() && e["created_at"].is_u64(), "event {i} has no kind or created_at");
    }
    Ok(events)
}

#[derive(Serialize, Debug, PartialEq)]
pub struct AckOut {
    pub id: String,
    pub accepted: bool,
    pub message: String,
}

#[derive(Serialize, Debug, Default)]
pub struct PushResult {
    /// Every event was accepted by the page.
    pub ok: bool,
    /// Streams opened before one reached the page.
    pub attempts: u32,
    pub established_ms: Option<u64>,
    pub acks: Vec<AckOut>,
    /// Ids the page refused or never answered.
    pub not_accepted: Vec<String>,
    pub error: Option<String>,
}

/// Send `events_json` (signed events) to the relay page `relay_npub`, and
/// report what the page answered, as JSON. Blocks up to `timeout`: call it off
/// the UI thread.
pub fn relay_push(relay_npub: &str, events_json: &str, timeout: Duration) -> Result<String, i32> {
    let relay = PeerIdentity::from_npub(relay_npub).map_err(|_| ERR_BAD_NPUB)?.npub();
    let events = parse_events(events_json).map_err(|e| {
        tracing::warn!("relay push: {e:#}");
        ERR_BAD_EVENTS
    })?;
    let socket = match state().as_ref() {
        None => return Err(ERR_NOT_RUNNING),
        Some(run) => run.relay_socket.clone().ok_or(ERR_RELAY_OFF)?,
    };
    // Outside the state lock: this blocks for seconds and `stop` needs it.
    let _one = PUSH.lock().unwrap_or_else(|e| e.into_inner());
    let result = push_over(&socket, &relay, &events, timeout);
    Ok(serde_json::to_string(&result).unwrap_or_else(|_| "{\"ok\":false}".into()))
}

fn push_over(socket: &Path, relay: &str, events: &[Value], timeout: Duration) -> PushResult {
    let end = Instant::now() + timeout;
    let mut result = PushResult::default();
    loop {
        let left = end.saturating_duration_since(Instant::now());
        if left.is_zero() {
            break;
        }
        result.attempts += 1;
        let mut link = match NativeLink::connect(socket, relay) {
            Ok(link) => link,
            Err(e) => {
                result.error = Some(format!("datagram API: {e}"));
                return result;
            }
        };
        match run_publish(&mut link, events, left.min(ATTEMPT)) {
            Ok(outcome) => {
                result.error = outcome.error.clone();
                if outcome.established_ms.is_some() {
                    result.established_ms = outcome.established_ms;
                    result.not_accepted = outcome.not_accepted(events).into_iter().map(str::to_owned).collect();
                    result.acks = outcome
                        .acks
                        .into_iter()
                        .map(|a| AckOut { id: a.id, accepted: a.accepted, message: a.message })
                        .collect();
                    result.ok = result.not_accepted.is_empty();
                    return result;
                }
            }
            Err(e) => result.error = Some(e.to_string()),
        }
        // The page has not opened its session yet: wait for its next dial.
        drop(link);
        std::thread::sleep(RETRY_PAUSE.min(end.saturating_duration_since(Instant::now())));
    }
    if result.error.is_none() {
        result.error = Some("the relay page never answered".into());
    }
    result.not_accepted = events.iter().filter_map(|e| e["id"].as_str().map(str::to_owned)).collect();
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    fn signed() -> Value {
        serde_json::json!({
            "id": "0e77648561adff088369d4c64da86cfba817cea6ff2b793cd273b35ce6271189",
            "pubkey": "a843a8261830c9a220f24a049ce449fde9ca89ea743aea7cf6cfb65f7e2eaff0",
            "created_at": 1792067525u64, "kind": 1, "tags": [], "content": "hi",
            "sig": "95fb078d036e45284bd6d95c77bc6c8d525af78d6a960b4101b6a67e734f70373628de86435ea8513c8c0769685dad9c6fa9aad132c7197eee6574182347667b",
        })
    }

    #[test]
    fn one_event_or_a_list() {
        assert_eq!(parse_events(&signed().to_string()).unwrap().len(), 1);
        let two = Value::Array(vec![signed(), signed()]);
        assert_eq!(parse_events(&two.to_string()).unwrap().len(), 2);
    }

    #[test]
    fn unsigned_or_malformed_events_are_refused() {
        let mut e = signed();
        e["sig"] = Value::from("00");
        assert!(parse_events(&e.to_string()).is_err());
        let mut e = signed();
        e.as_object_mut().unwrap().remove("id");
        assert!(parse_events(&e.to_string()).is_err());
        let mut e = signed();
        e["kind"] = Value::from("1");
        assert!(parse_events(&e.to_string()).is_err());
        assert!(parse_events("[]").is_err());
        assert!(parse_events("\"x\"").is_err());
        assert!(parse_events("not json").is_err());
        let many = Value::Array(vec![signed(); MAX_EVENTS + 1]);
        assert!(parse_events(&many.to_string()).is_err());
    }

    #[test]
    fn seeds_render_and_validate() {
        for seed in PUBLIC_SEEDS {
            let y = seed_yaml(seed).unwrap();
            assert!(y.contains(seed.npub) && y.contains(seed.addr), "{y}");
        }
        let bad = |addr| seed_yaml(&Seed { npub: PUBLIC_SEEDS[0].npub, addr });
        assert!(bad("fips1.iris.to").is_err());
        assert!(bad("evil\"\n  x: 1:51820").is_err());
        assert!(bad("host:99999").is_err());
        assert!(seed_yaml(&Seed { npub: "npub1nope", addr: "a:1" }).is_err());
    }

    #[test]
    fn socket_path_is_off_absolute_and_short() {
        assert_eq!(native_api_yaml("").unwrap(), "");
        assert!(native_api_yaml("relative.sock").is_err());
        assert!(native_api_yaml(&format!("/{}", "a".repeat(MAX_SOCKET_PATH))).is_err());
        let y = native_api_yaml("/tmp/a\"b.sock").unwrap();
        assert!(y.contains("enabled: true") && y.contains(r#""/tmp/a\"b.sock""#), "{y}");
    }

    #[test]
    fn push_needs_a_running_node_with_the_socket() {
        let one = signed().to_string();
        assert_eq!(relay_push("npub1nope", &one, Duration::from_millis(1)), Err(ERR_BAD_NPUB));
        assert_eq!(relay_push(PUBLIC_SEEDS[0].npub, "[]", Duration::from_millis(1)), Err(ERR_BAD_EVENTS));
        if state().is_none() {
            assert_eq!(relay_push(PUBLIC_SEEDS[0].npub, &one, Duration::from_millis(1)), Err(ERR_NOT_RUNNING));
        }
    }
}
