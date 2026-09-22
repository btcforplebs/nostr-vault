//! Byte-transparent TCP <-> QUIC splicing in both directions.

pub mod egress;
pub mod ingress;

pub use ingress::Ingress;
