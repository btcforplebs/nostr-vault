//! QUIC over the FIPS mesh.

pub mod addr_map;
pub mod quic;
pub mod tls;
pub mod udp_socket;

pub use addr_map::AddrMap;
pub use quic::{FipsQuic, SERVICE_PORT};
pub use udp_socket::FipsUdpSocket;
