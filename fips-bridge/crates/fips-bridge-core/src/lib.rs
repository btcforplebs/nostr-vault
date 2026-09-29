//! Core of the Nostr Vault FIPS bridge.
//!
//! Everything on the per-packet path lives here, in Rust. The host apps
//! (Swift/Kotlin) only ever touch a small control-plane C ABI — see
//! `FIPS_FFI_PLAN.md` for why that boundary is where it is.

pub mod endpoint;
pub mod proxy;
pub mod transport;

// Re-exported so downstream crates bind to exactly the quinn/rustls versions
// this crate was built against, rather than resolving their own.
pub use quinn;
pub use rustls;

pub use endpoint::{bind_endpoint, public_mesh_peers, seed_alias, EndpointOptions, PUBLIC_MESH_SEEDS};
pub use transport::{FipsQuic, FipsUdpSocket, SERVICE_PORT};
