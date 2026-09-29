//! Device check of the library path the app uses: start, export a port,
//! print the status, run until killed.
//!   share <peer-npub> <local-port> [--lan] [--file <path>]
//! With --file, also serves <path> over plain HTTP on 127.0.0.1:<local-port>,
//! so a phone can be tested without anything else listening on it.
use std::io::{Read, Write};

fn serve_file(port: u16, path: String) {
    let listener = std::net::TcpListener::bind(("127.0.0.1", port)).expect("bind file server");
    for stream in listener.incoming().flatten() {
        let path = path.clone();
        std::thread::spawn(move || {
            let mut stream = stream;
            let mut req = [0u8; 2048];
            let n = stream.read(&mut req).unwrap_or(0);
            let head = String::from_utf8_lossy(&req[..n]);
            let body = if head.starts_with("GET /blob") {
                std::fs::read(&path).unwrap_or_default()
            } else {
                b"hello-nvfips\n".to_vec()
            };
            let _ = write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            );
            let _ = stream.write_all(&body);
        });
    }
}

fn main() {
    nvfips::init_logging();
    let args: Vec<String> = std::env::args().collect();
    let port: u16 = args[2].parse().unwrap();
    if let Some(i) = args.iter().position(|a| a == "--file") {
        let path = args[i + 1].clone();
        std::thread::spawn(move || serve_file(port, path));
    }
    let opts = nvfips::StartOptions {
        peers: vec![args[1].clone()],
        lan: args.iter().any(|a| a == "--lan"),
        ..Default::default()
    };
    let nsec_path = std::env::var("NVFIPS_NSEC").unwrap_or_else(|_| "/tmp/nvfips-share.nsec".into());
    let nsec_path = std::path::Path::new(&nsec_path);
    let nsec = std::fs::read_to_string(nsec_path).unwrap_or_else(|_| {
        let n = nvfips::generate_nsec();
        std::fs::write(nsec_path, &n).unwrap();
        n
    });
    nvfips::start(nsec.trim(), &opts).expect("start");
    assert_eq!(nvfips::export(port), 0);
    println!("{}", nvfips::status_json());
    loop {
        std::thread::sleep(std::time::Duration::from_secs(3600));
    }
}
