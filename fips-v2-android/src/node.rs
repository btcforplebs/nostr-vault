//! A FIPS node on its own thread and runtime: `start` must run inside a
//! runtime, and the rx loop then owns the node until it is told to stop.

use std::net::Ipv6Addr;
use std::time::Duration;

use anyhow::{Context, Result};
use fips::{Config, Node};

pub(crate) struct Spawned {
    pub npub: String,
    pub address: Ipv6Addr,
    pub mtu: usize,
    pub tun: (fips::upper::tun::TunOutboundTx, std::sync::mpsc::Receiver<Vec<u8>>),
    pub control: tokio::sync::mpsc::Sender<fips::control::ControlMessage>,
    pub stop: tokio::sync::oneshot::Sender<()>,
    pub thread: std::thread::JoinHandle<()>,
}

pub(crate) fn spawn(config: Config, name: &str) -> Result<Spawned> {
    let (ready_tx, ready_rx) = std::sync::mpsc::channel();
    let (stop_tx, stop_rx) = tokio::sync::oneshot::channel::<()>();
    let thread = std::thread::Builder::new()
        .name(name.into())
        .spawn(move || {
            let rt = match tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .build()
            {
                Ok(rt) => rt,
                Err(e) => {
                    let _ = ready_tx.send(Err(anyhow::anyhow!("runtime: {e}")));
                    return;
                }
            };
            rt.block_on(async move {
                let mut node = match Node::new(config) {
                    Ok(n) => n,
                    Err(e) => {
                        let _ = ready_tx.send(Err(anyhow::anyhow!("Node::new: {e}")));
                        return;
                    }
                };
                let tun = node.enable_app_owned_tun();
                let control = node.enable_embedded_control();
                let npub = node.npub();
                let address = node.identity().address().to_ipv6();
                let mtu = node.effective_ipv6_mtu() as usize;
                if let Err(e) = node.start().await {
                    let _ = ready_tx.send(Err(anyhow::anyhow!("start: {e}")));
                    return;
                }
                let _ = ready_tx.send(Ok((npub, address, mtu, tun, control)));
                if let Err(e) = node
                    .run_rx_loop_with_shutdown(async {
                        let _ = stop_rx.await;
                    })
                    .await
                {
                    tracing::warn!("fips rx loop ended: {e}");
                }
                if let Err(e) = node.stop().await {
                    tracing::warn!("fips stop: {e}");
                }
            });
        })?;

    let (npub, address, mtu, tun, control) =
        ready_rx.recv_timeout(Duration::from_secs(30)).context("node did not report ready")??;
    Ok(Spawned { npub, address, mtu, tun, control, stop: stop_tx, thread })
}
