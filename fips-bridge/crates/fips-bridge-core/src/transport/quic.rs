//! Assembling a quinn endpoint on top of the FIPS mesh.

use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use fips_endpoint::{FipsEndpoint, PeerIdentity};
use quinn::crypto::rustls::{QuicClientConfig, QuicServerConfig};

use super::addr_map::AddrMap;
use super::tls;
use super::udp_socket::FipsUdpSocket;

/// FSP service port the bridge claims. 256-258 are reserved by FIPS itself.
pub const SERVICE_PORT: u16 = 4242;

const ALPN: &[u8] = b"haven-fips-bridge/1";

/// QUIC's floor (RFC 9000 anti-amplification). quinn will not go below it, and
/// the measured single-fragment FIPS payload must stay above it.
const QUIC_MIN_MTU: u16 = 1200;

pub struct FipsQuic {
    pub endpoint: quinn::Endpoint,
    pub map: Arc<AddrMap>,
    pub fips: Arc<FipsEndpoint>,
}

impl FipsQuic {
    /// Register the service port, wrap it as a quinn socket, and stand up an
    /// endpoint that can both accept and dial.
    pub async fn new(fips: Arc<FipsEndpoint>) -> Result<Self> {
        // rustls 0.23 requires an explicitly installed provider. Another
        // component may have installed one already; that is not an error.
        let _ = rustls::crypto::ring::default_provider().install_default();

        let receiver = fips
            .register_service_receiver(SERVICE_PORT)
            .await
            .context("register FIPS service receiver")?;

        let map = Arc::new(AddrMap::new());
        let local_ipv6 = fips.address().to_ipv6();
        let socket = FipsUdpSocket::new(
            fips.clone(),
            receiver,
            SERVICE_PORT,
            local_ipv6,
            map.clone(),
        );

        let transport = transport_config();

        // Server side.
        let (cert, key) = tls::self_signed()?;
        let mut server_crypto = rustls::ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(vec![cert], key)
            .context("server cert")?;
        server_crypto.alpn_protocols = vec![ALPN.to_vec()];
        let mut server_config =
            quinn::ServerConfig::with_crypto(Arc::new(QuicServerConfig::try_from(server_crypto)?));
        server_config.transport_config(transport.clone());

        let mut endpoint = quinn::Endpoint::new_with_abstract_socket(
            quinn::EndpointConfig::default(),
            Some(server_config),
            socket,
            Arc::new(quinn::TokioRuntime),
        )
        .context("quinn endpoint over FIPS socket")?;

        // Client side.
        let mut client_crypto = rustls::ClientConfig::builder()
            .dangerous()
            .with_custom_certificate_verifier(tls::FipsAuthenticatedVerifier::new())
            .with_no_client_auth();
        client_crypto.alpn_protocols = vec![ALPN.to_vec()];
        let mut client_config =
            quinn::ClientConfig::new(Arc::new(QuicClientConfig::try_from(client_crypto)?));
        client_config.transport_config(transport);
        endpoint.set_default_client_config(client_config);

        Ok(Self { endpoint, map, fips })
    }

    /// Dial a FIPS peer over the mesh.
    pub async fn connect(&self, peer: PeerIdentity) -> Result<quinn::Connection> {
        // Registering the peer is what lets `try_send` translate quinn's
        // SocketAddr back into a FIPS identity.
        let addr = self.map.insert(peer);
        let connection = self
            .endpoint
            .connect(addr, "fips.local")
            .context("quinn connect")?
            .await
            .context("quinn handshake")?;
        Ok(connection)
    }

    /// Accept the next inbound connection.
    pub async fn accept(&self) -> Option<Result<quinn::Connection>> {
        let incoming = self.endpoint.accept().await?;
        Some(
            incoming
                .await
                .context("accept incoming")
                .map_err(anyhow::Error::from),
        )
    }
}

fn transport_config() -> Arc<quinn::TransportConfig> {
    let mut transport = quinn::TransportConfig::default();

    // FIPS owns path-MTU discovery; quinn probing on top of it is noise, and
    // probes above the single-fragment size would be actively misleading.
    transport.initial_mtu(QUIC_MIN_MTU);
    transport.min_mtu(QUIC_MIN_MTU);
    transport.mtu_discovery_config(None);

    // The mesh can be quiet for long stretches; keep NAT bindings warm.
    transport.keep_alive_interval(Some(Duration::from_secs(10)));

    Arc::new(transport)
}
