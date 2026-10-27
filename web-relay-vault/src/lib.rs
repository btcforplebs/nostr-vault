//! Vault side of the browser relay (G3): the vault opens a TCP/FIPS stream to a
//! `nostrvault.app/relay/` page on FSP service port 7447 and speaks NIP-01 over
//! it, one JSON array per `\n`-terminated line.
//!
//! The core is transport-agnostic. [`session::RelaySession`] is sans-I/O: it
//! takes datagrams in and hands datagrams out, and knows nothing about how they
//! travel. A transport is a [`link::DatagramLink`] for one peer and one port
//! pair. Adapters:
//! - `native` (feature): a node's datagram API socket
//!   (`fips::native::client::FipsStream`). Linux, FreeBSD and macOS on a
//!   standalone node; Android and iOS inside the app's own node (libnvfips,
//!   `fips-v2-android/src/relay_link.rs`), on our fork.

pub mod client;
pub mod link;
pub mod ndjson;
pub mod session;

#[cfg(all(
    feature = "native",
    any(target_os = "linux", target_os = "android", target_os = "freebsd", target_os = "macos", target_os = "ios")
))]
pub mod native;

/// FSP service port of the browser relay. Also the TCP listen port inside
/// TCP/FIPS. Both ends send from and to this port.
pub const RELAY_SERVICE_PORT: u16 = 7447;
