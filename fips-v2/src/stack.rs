//! Userspace TCP/IP over the FIPS app-owned TUN channels.
//!
//! smoltcp terminates the mesh IPv6 packets; each mesh TCP connection is
//! spliced to an ordinary localhost TCP stream, so an unmodified relay or
//! WebSocket client sits on either end.

use anyhow::{Context, Result};
use fips::upper::tun::TunOutboundTx;
use smoltcp::iface::{Config, Interface, SocketHandle, SocketSet};
use smoltcp::phy::{Device, DeviceCapabilities, Medium, RxToken, TxToken};
use smoltcp::socket::tcp;
use smoltcp::time::Instant;
use smoltcp::wire::{HardwareAddress, IpAddress, IpCidr, Ipv6Address};
use std::collections::VecDeque;
use std::io::{ErrorKind, Read, Write};
use std::net::{Ipv6Addr, SocketAddr, TcpListener, TcpStream};
use std::sync::mpsc::Receiver;
use std::time::Duration;

use crate::MESH_PORT;

pub enum Mode {
    /// Accept mesh connections on MESH_PORT, splice each to `forward`.
    Serve { forward: SocketAddr },
    /// Accept local connections on `listen`, splice each to `peer`:MESH_PORT.
    Connect { listen: SocketAddr, peer: Ipv6Addr },
}

struct ChannelDevice {
    to_mesh: TunOutboundTx,
    from_mesh: Receiver<Vec<u8>>,
    mtu: usize,
    rx_queue: VecDeque<Vec<u8>>,
}

struct Rx(Vec<u8>);

/// FIPSV2_PKTLOG=1 prints one line per IPv6/TCP packet crossing the device.
fn pktlog(dir: &str, pkt: &[u8]) {
    if std::env::var_os("FIPSV2_PKTLOG").is_none() || pkt.len() < 40 {
        return;
    }
    let src = Ipv6Addr::from(<[u8; 16]>::try_from(&pkt[8..24]).unwrap());
    let dst = Ipv6Addr::from(<[u8; 16]>::try_from(&pkt[24..40]).unwrap());
    let (nh, t) = (pkt[6], &pkt[40..]);
    if nh == 6 && t.len() >= 14 {
        let sp = u16::from_be_bytes([t[0], t[1]]);
        let dp = u16::from_be_bytes([t[2], t[3]]);
        eprintln!("pkt {dir} {src}:{sp} -> {dst}:{dp} flags={:#04x} len={}", t[13], pkt.len());
    } else {
        eprintln!("pkt {dir} {src} -> {dst} nh={nh} len={}", pkt.len());
    }
}
struct Tx<'a>(&'a TunOutboundTx);

impl RxToken for Rx {
    fn consume<R, F: FnOnce(&[u8]) -> R>(self, f: F) -> R {
        f(&self.0)
    }
}

impl TxToken for Tx<'_> {
    fn consume<R, F: FnOnce(&mut [u8]) -> R>(self, len: usize, f: F) -> R {
        let mut buf = vec![0u8; len];
        let r = f(&mut buf);
        pktlog("out", &buf);
        // Block (this is a plain thread, not a tokio worker): dropping on a
        // full queue cost ~7x throughput in retransmit timeouts.
        let _ = self.0.blocking_send(buf);
        r
    }
}

impl Device for ChannelDevice {
    type RxToken<'a> = Rx;
    type TxToken<'a> = Tx<'a>;

    fn receive(&mut self, _: Instant) -> Option<(Rx, Tx<'_>)> {
        while let Ok(pkt) = self.from_mesh.try_recv() {
            self.rx_queue.push_back(pkt);
        }
        let pkt = self.rx_queue.pop_front()?;
        pktlog("in ", &pkt);
        Some((Rx(pkt), Tx(&self.to_mesh)))
    }

    fn transmit(&mut self, _: Instant) -> Option<Tx<'_>> {
        Some(Tx(&self.to_mesh))
    }

    fn capabilities(&self) -> DeviceCapabilities {
        let mut caps = DeviceCapabilities::default();
        caps.medium = Medium::Ip;
        // MSS follows from this, which is the clamping FIPS asks an
        // app-owned TUN to do.
        caps.max_transmission_unit = self.mtu;
        caps
    }
}

struct Splice {
    handle: SocketHandle,
    stream: TcpStream,
    /// mesh -> local bytes the local stream has not accepted yet.
    pending: Vec<u8>,
    local_eof: bool,
    local_shut: bool,
}

fn new_socket() -> tcp::Socket<'static> {
    let mut s = tcp::Socket::new(
        tcp::SocketBuffer::new(vec![0; 256 * 1024]),
        tcp::SocketBuffer::new(vec![0; 256 * 1024]),
    );
    s.set_nagle_enabled(false);
    s.set_keep_alive(Some(smoltcp::time::Duration::from_secs(20)));
    s
}

pub fn run(
    my_addr: Ipv6Addr,
    mtu: usize,
    to_mesh: TunOutboundTx,
    from_mesh: Receiver<Vec<u8>>,
    mode: Mode,
) -> Result<()> {
    let mut dev = ChannelDevice { to_mesh, from_mesh, mtu, rx_queue: VecDeque::new() };
    let mut iface = Interface::new(Config::new(HardwareAddress::Ip), &mut dev, Instant::now());
    iface.update_ip_addrs(|a| {
        // /8 makes all of fd::/8 on-link; Medium::Ip has no neighbour step.
        let _ = a.push(IpCidr::new(IpAddress::Ipv6(Ipv6Address::from(my_addr)), 8));
    });

    let mut sockets = SocketSet::new(vec![]);
    let mut listeners: Vec<SocketHandle> = Vec::new();
    let mut splices: Vec<Splice> = Vec::new();
    let mut next_port: u16 = 49152;

    let local_listener = match &mode {
        Mode::Connect { listen, .. } => {
            let l = TcpListener::bind(listen).with_context(|| format!("bind {listen}"))?;
            l.set_nonblocking(true)?;
            println!("listening on {listen} -> peer [..]:{MESH_PORT}");
            Some(l)
        }
        Mode::Serve { forward } => {
            println!("serving mesh [{my_addr}]:{MESH_PORT} -> {forward}");
            None
        }
    };

    let mut buf = vec![0u8; 64 * 1024];
    loop {
        let now = Instant::now();
        iface.poll(now, &mut dev, &mut sockets);
        let mut busy = false;

        match &mode {
            Mode::Serve { forward } => {
                // Keep a few listeners armed; smoltcp listens one-per-socket.
                while listeners.len() < 4 {
                    let mut s = new_socket();
                    s.listen(MESH_PORT)?;
                    listeners.push(sockets.add(s));
                }
                let mut i = 0;
                while i < listeners.len() {
                    let h = listeners[i];
                    let s = sockets.get_mut::<tcp::Socket>(h);
                    if s.is_active() {
                        listeners.swap_remove(i);
                        let remote = s.remote_endpoint();
                        match TcpStream::connect_timeout(forward, Duration::from_secs(3)) {
                            Ok(stream) => {
                                stream.set_nonblocking(true)?;
                                stream.set_nodelay(true)?;
                                println!("mesh accept {remote:?} -> {forward}");
                                splices.push(Splice { handle: h, stream, pending: Vec::new(), local_eof: false, local_shut: false });
                            }
                            Err(e) => {
                                eprintln!("forward {forward} failed: {e}");
                                s.abort();
                            }
                        }
                        busy = true;
                    } else {
                        i += 1;
                    }
                }
            }
            Mode::Connect { peer, .. } => {
                if let Some(l) = &local_listener {
                    while let Ok((stream, from)) = l.accept() {
                        stream.set_nonblocking(true)?;
                        stream.set_nodelay(true)?;
                        let mut s = new_socket();
                        next_port = if next_port == u16::MAX { 49152 } else { next_port + 1 };
                        s.connect(
                            iface.context(),
                            (IpAddress::Ipv6(Ipv6Address::from(*peer)), MESH_PORT),
                            next_port,
                        )?;
                        println!("local accept {from} -> mesh [{peer}]:{MESH_PORT}");
                        splices.push(Splice { handle: sockets.add(s), stream, pending: Vec::new(), local_eof: false, local_shut: false });
                        busy = true;
                    }
                }
            }
        }

        splices.retain_mut(|sp| {
            let s = sockets.get_mut::<tcp::Socket>(sp.handle);

            // mesh -> local
            if sp.pending.is_empty() && s.can_recv() {
                if let Ok(n) = s.recv_slice(&mut buf) {
                    sp.pending.extend_from_slice(&buf[..n]);
                    busy |= n > 0;
                }
            }
            if !sp.pending.is_empty() {
                match sp.stream.write(&sp.pending) {
                    Ok(n) => {
                        sp.pending.drain(..n);
                        busy = true;
                    }
                    Err(e) if e.kind() == ErrorKind::WouldBlock => {}
                    Err(e) => {
                        eprintln!("local write failed: {e}");
                        s.abort();
                    }
                }
            }

            // local -> mesh
            if !sp.local_eof && s.may_send() && s.send_capacity() > s.send_queue() {
                let room = (s.send_capacity() - s.send_queue()).min(buf.len());
                match sp.stream.read(&mut buf[..room]) {
                    Ok(0) => {
                        sp.local_eof = true;
                        s.close();
                    }
                    Ok(n) => {
                        let _ = s.send_slice(&buf[..n]);
                        busy = true;
                    }
                    Err(e) if e.kind() == ErrorKind::WouldBlock => {}
                    Err(e) => {
                        eprintln!("local read failed: {e}");
                        sp.local_eof = true;
                        s.abort();
                    }
                }
            }

            // Mesh side finished sending and everything is flushed locally.
            let mesh_fin = matches!(
                s.state(),
                tcp::State::CloseWait | tcp::State::LastAck | tcp::State::Closing | tcp::State::TimeWait
            );
            if mesh_fin && !s.can_recv() && sp.pending.is_empty() && !sp.local_shut {
                sp.local_shut = true;
                let _ = sp.stream.shutdown(std::net::Shutdown::Write);
            }

            let done = s.state() == tcp::State::Closed
                || (s.state() == tcp::State::TimeWait && sp.pending.is_empty());
            if done {
                sockets.remove(sp.handle);
            }
            !done
        });

        if !busy {
            let wait = iface
                .poll_delay(Instant::now(), &sockets)
                .map(|d| Duration::from_micros(d.total_micros()))
                .unwrap_or(Duration::from_millis(5))
                .min(Duration::from_millis(2));
            std::thread::sleep(wait);
        }
    }
}
