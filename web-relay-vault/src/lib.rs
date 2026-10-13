//! Vault side of the browser relay (G3): the vault opens a TCP/FIPS stream to a
//! `nostrvault.app/relay/` page on FSP service port 7447 and speaks NIP-01 over
//! it, one JSON array per `\n`-terminated line.
//!
//! The core is transport-agnostic. [`session::RelaySession`] is sans-I/O: it
//! takes datagrams in and hands datagrams out, and knows nothing about how they
//! travel. A transport is a [`link::DatagramLink`] for one peer and one port
//! pair. Adapters:
//! - `native` (feature, Linux/FreeBSD/macOS): a jmcorgan v0.5.2 node's native
//!   datagram API (`fips::native::client::FipsStream`).
//! - Not yet: the in-process `fips-bridge-core` endpoint the shipped apps run.
//!   That is a second `DatagramLink`, not a change here.

pub mod client;
pub mod link;
pub mod ndjson;
pub mod session;

#[cfg(all(
    feature = "native",
    any(target_os = "linux", target_os = "freebsd", target_os = "macos")
))]
pub mod native;

/// FSP service port of the browser relay. Also the TCP listen port inside
/// TCP/FIPS. Both ends send from and to this port.
pub const RELAY_SERVICE_PORT: u16 = 7447;
