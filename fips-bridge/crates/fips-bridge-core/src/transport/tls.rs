//! TLS for QUIC-over-FIPS.
//!
//! QUIC mandates TLS, but the certificate check is redundant here: FIPS has
//! already authenticated the peer via Noise IK before a single byte reaches
//! quinn, and `FipsEndpointServiceDatagram::source_peer` is that authenticated
//! identity. The trust anchor is FIPS, not X.509.
//!
//! So we generate a throwaway self-signed cert and accept any peer cert. What
//! we must NOT do is let that become "we turned off certificate checking" in a
//! security review — the real check is upstream, and Phase 1 should additionally
//! pin the cert's SPKI hash to the peer's npub so the two layers agree on who
//! the peer is.

use std::sync::Arc;

use anyhow::{Context, Result};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, ServerName, UnixTime};
use rustls::{DigitallySignedStruct, SignatureScheme};

/// A self-signed cert/key pair for this endpoint.
pub fn self_signed() -> Result<(CertificateDer<'static>, PrivateKeyDer<'static>)> {
    let certified = rcgen::generate_simple_self_signed(vec!["fips.local".to_string()])
        .context("generate self-signed cert")?;
    let cert = CertificateDer::from(certified.cert.der().to_vec());
    let key = PrivateKeyDer::try_from(certified.key_pair.serialize_der())
        .map_err(|e| anyhow::anyhow!("serialize private key: {e}"))?;
    Ok((cert, key))
}

/// Accepts any server certificate.
///
/// Sound *only* because FIPS authenticated the peer first. See module docs.
#[derive(Debug)]
pub struct FipsAuthenticatedVerifier {
    provider: Arc<rustls::crypto::CryptoProvider>,
}

impl FipsAuthenticatedVerifier {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            provider: Arc::new(rustls::crypto::ring::default_provider()),
        })
    }
}

impl ServerCertVerifier for FipsAuthenticatedVerifier {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider
            .signature_verification_algorithms
            .supported_schemes()
    }
}
