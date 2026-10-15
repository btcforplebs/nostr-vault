//! `DatagramLink` over a jmcorgan v0.5.2 node's native datagram API.
//!
//! The flow holds local FSP port 7447 because the page's `FipsTcpEndpoint`
//! sends every segment from 7447 to 7447, not back to the sender's port.

use std::io;
use std::path::Path;
use std::time::Duration;

use fips::native::client::FipsStream;

use crate::link::DatagramLink;
use crate::RELAY_SERVICE_PORT;

pub struct NativeLink {
    stream: FipsStream,
    buf: Vec<u8>,
}

impl NativeLink {
    /// `api_sock`: the node's `node.native_api.socket_path`. `relay`: the
    /// page's npub. The node's own identity is the vault key the page gates on.
    ///
    /// Retries `EADDRINUSE` for a few seconds: the node frees a closed flow's
    /// port asynchronously, so a run straight after another can find 7447 held.
    pub fn connect(api_sock: &Path, relay: &str) -> io::Result<Self> {
        let mut tries = 0;
        let stream = loop {
            match FipsStream::connect_at(api_sock, RELAY_SERVICE_PORT, (relay, RELAY_SERVICE_PORT)) {
                Err(e) if e.kind() == io::ErrorKind::AddrInUse && tries < 30 => {
                    tries += 1;
                    std::thread::sleep(Duration::from_millis(200));
                }
                other => break other?,
            }
        };
        let buf = vec![0; stream.max_payload().max(1)];
        Ok(Self { stream, buf })
    }

    pub fn local_npub(&self) -> String {
        self.stream.local_addr().to_string()
    }
}

impl DatagramLink for NativeLink {
    fn send(&mut self, datagram: &[u8]) -> io::Result<()> {
        self.stream.send(datagram)
    }

    fn recv(&mut self, timeout: Duration) -> io::Result<Option<Vec<u8>>> {
        self.stream.set_read_timeout(Some(timeout.max(Duration::from_millis(1))))?;
        match self.stream.recv(&mut self.buf) {
            // macOS reports a closing flow as a zero-length read first; no
            // datagram here is ever empty, so it carries nothing.
            Ok(0) => Ok(None),
            Ok(n) => Ok(Some(self.buf[..n].to_vec())),
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => Ok(None),
            Err(e) => Err(e),
        }
    }

    fn max_payload(&self) -> usize {
        self.stream.max_payload()
    }
}
