//! The one thing a transport has to provide: datagrams to and from one peer on
//! FSP port 7447 at both ends.

use std::io;
use std::time::Duration;

pub trait DatagramLink {
    /// Send one datagram (one TCP/FIPS segment) to the peer.
    fn send(&mut self, datagram: &[u8]) -> io::Result<()>;

    /// Wait up to `timeout` for one datagram from the peer. `Ok(None)` means
    /// nothing arrived in time, not that the peer went away.
    fn recv(&mut self, timeout: Duration) -> io::Result<Option<Vec<u8>>>;

    /// Largest datagram the link will carry. Segments are sized below it.
    fn max_payload(&self) -> usize;
}
