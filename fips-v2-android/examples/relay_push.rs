//! Mac check of the library path the app uses for the browser relay: start
//! the node the way the app does (leaf-only, public seeds, datagram API
//! socket), then hand signed events to a relay page and print what it said.
//!   relay_push <nsec> <relay-npub> <events.json> [timeout-secs]
//! Pair the page with this node's npub (printed first) before it gives up.

fn main() {
    nvfips::init_logging();
    let args: Vec<String> = std::env::args().collect();
    let (nsec, relay, file) = (&args[1], &args[2], &args[3]);
    let timeout = std::time::Duration::from_secs(args.get(4).and_then(|s| s.parse().ok()).unwrap_or(120));
    let socket = std::env::temp_dir().join(format!("nvfips-relay-{}.sock", std::process::id()));
    let opts = serde_json::json!({ "public_seeds": true, "relay_socket": socket.to_str().unwrap() });
    let opts: nvfips::StartOptions = serde_json::from_value(opts).unwrap();
    nvfips::start(nsec, &opts).expect("start");
    println!("status {}", nvfips::status_json());
    let events = std::fs::read_to_string(file).expect("events file");
    match nvfips::relay_push(relay, &events, timeout) {
        Ok(json) => println!("result {json}"),
        Err(code) => println!("error code {code}"),
    }
    nvfips::stop();
}
