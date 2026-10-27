//! From this vault node, send already-signed events to the browser relay over
//! TCP/FIPS 7447 and wait for its OK.
//!
//! ```text
//! g3-event <api.sock> <relay-npub> <events.json> [deadline-secs]
//! ```
//! `events.json` holds one signed event or an array of them. Prints one JSON
//! line with the outcome. Exit 0 only if the page accepted every event.

#[cfg(all(feature = "native", any(target_os = "linux", target_os = "freebsd", target_os = "macos")))]
fn main() -> std::process::ExitCode {
    use serde_json::{json, Value};
    use std::path::Path;
    use std::time::Duration;
    use web_relay_vault::{client::run_publish, native::NativeLink};

    let args: Vec<String> = std::env::args().skip(1).collect();
    let (Some(sock), Some(relay), Some(file)) = (args.first(), args.get(1), args.get(2)) else {
        eprintln!("usage: g3-event <api.sock> <relay-npub> <events.json> [deadline-secs]");
        return std::process::ExitCode::from(2);
    };
    let text = std::fs::read_to_string(file).expect("cannot read events file");
    let events: Vec<Value> = match serde_json::from_str::<Value>(&text).expect("events file is not JSON") {
        Value::Array(a) => a,
        one => vec![one],
    };
    let deadline = Duration::from_secs(args.get(3).and_then(|s| s.parse().ok()).unwrap_or(45));

    let mut link = match NativeLink::connect(Path::new(sock), relay) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("g3-event: native connect failed: {e}");
            return std::process::ExitCode::from(3);
        }
    };
    let vault = link.local_npub();
    let outcome = match run_publish(&mut link, &events, deadline) {
        Ok(o) => o,
        Err(e) => {
            eprintln!("g3-event: {e}");
            return std::process::ExitCode::from(4);
        }
    };
    let missing = outcome.not_accepted(&events);
    let acks: Vec<Value> = outcome.acks.iter().map(|a| json!([a.id, a.accepted, a.message])).collect();
    println!(
        "{}",
        json!({
            "vault": vault, "relay": relay, "sent": events.len(),
            "established_ms": outcome.established_ms, "done_ms": outcome.done_ms,
            "acks": acks, "not_accepted": missing, "notices": outcome.notices,
            "datagrams_out": outcome.datagrams_out, "datagrams_in": outcome.datagrams_in,
            "error": outcome.error,
        })
    );
    if missing.is_empty() { std::process::ExitCode::SUCCESS } else { std::process::ExitCode::FAILURE }
}

#[cfg(not(all(feature = "native", any(target_os = "linux", target_os = "freebsd", target_os = "macos"))))]
fn main() {
    eprintln!("g3-event needs the `native` feature on Linux, FreeBSD or macOS");
    std::process::exit(2);
}
