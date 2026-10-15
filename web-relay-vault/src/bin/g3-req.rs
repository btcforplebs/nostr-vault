//! G3 probe: from this vault node, REQ the browser relay over TCP/FIPS 7447.
//!
//! ```text
//! g3-req <api.sock> <relay-npub> [<note-id-hex> | '<filter-json>'] [deadline-secs]
//! ```
//! Prints one JSON line with the outcome. Exit 0 only on EOSE.

#[cfg(all(feature = "native", any(target_os = "linux", target_os = "freebsd", target_os = "macos")))]
fn main() -> std::process::ExitCode {
    use serde_json::{json, Value};
    use std::path::Path;
    use std::time::Duration;
    use web_relay_vault::{client::run_req, native::NativeLink};

    let args: Vec<String> = std::env::args().skip(1).collect();
    let (Some(sock), Some(relay)) = (args.first(), args.get(1)) else {
        eprintln!("usage: g3-req <api.sock> <relay-npub> [<note-id-hex> | '<filter-json>'] [deadline-secs]");
        return std::process::ExitCode::from(2);
    };
    let filter: Value = match args.get(2) {
        None => json!({ "kinds": [1], "limit": 3 }),
        Some(f) if f.starts_with('{') => serde_json::from_str(f).expect("filter is not JSON"),
        Some(id) => json!({ "ids": [id] }),
    };
    let deadline = Duration::from_secs(args.get(3).and_then(|s| s.parse().ok()).unwrap_or(45));

    let mut link = match NativeLink::connect(Path::new(sock), relay) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("g3-req: native connect failed: {e}");
            return std::process::ExitCode::from(3);
        }
    };
    let vault = link.local_npub();
    let outcome = match run_req(&mut link, "g3", filter.clone(), deadline) {
        Ok(o) => o,
        Err(e) => {
            eprintln!("g3-req: {e}");
            return std::process::ExitCode::from(4);
        }
    };
    let ids: Vec<&str> = outcome.events.iter().filter_map(|e| e["id"].as_str()).collect();
    println!(
        "{}",
        json!({
            "vault": vault, "relay": relay, "filter": filter,
            "established_ms": outcome.established_ms, "eose_ms": outcome.eose_ms,
            "events": ids.len(), "ids": ids, "refusals": outcome.refusals,
            "datagrams_out": outcome.datagrams_out, "datagrams_in": outcome.datagrams_in,
            "error": outcome.error,
        })
    );
    if outcome.eose_ms.is_some() { std::process::ExitCode::SUCCESS } else { std::process::ExitCode::FAILURE }
}

#[cfg(not(all(feature = "native", any(target_os = "linux", target_os = "freebsd", target_os = "macos"))))]
fn main() {
    eprintln!("g3-req needs the `native` feature on Linux, FreeBSD or macOS");
    std::process::exit(2);
}
