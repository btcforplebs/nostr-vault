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
use std::collections::{HashMap, VecDeque};
use std::io::{ErrorKind, Read, Write};
use std::net::{Ipv6Addr, SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::Receiver;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::MESH_PORT;

pub enum Mode {
    /// Accept mesh connections on MESH_PORT, splice each to `forward`.
    Serve { forward: SocketAddr },
    /// Accept local connections on `listen`, splice each to `peer`:MESH_PORT.
    Connect { listen: SocketAddr, peer: Ipv6Addr },
}

/// Which side opened a splice: a peer reading our vault, or us reading theirs.
#[derive(Clone, Copy, PartialEq)]
enum Kind {
    Served,
    Read,
}

/// Live counters, readable from any thread while the stack runs.
#[derive(Default)]
pub struct Counters {
    pub served_open: AtomicU64,
    pub served_total: AtomicU64,
    /// Bytes from the mesh into the local relay, and back out to the mesh.
    pub served_rx: AtomicU64,
    pub served_tx: AtomicU64,
    pub read_open: AtomicU64,
    pub read_total: AtomicU64,
    /// Bytes from friends' vaults, and requests sent to them.
    pub read_rx: AtomicU64,
    pub read_tx: AtomicU64,
}

/// Runtime control of a running stack. Shared with the thread that drives it.
#[derive(Default)]
pub struct Control {
    /// Where mesh :MESH_PORT connections go. `None` refuses them, and turning
    /// it off cuts the connections already being served.
    serve: Mutex<Option<SocketAddr>>,
    /// Bumped by each `set_serve`; the stack copies it once the change is live.
    serve_gen: AtomicU64,
    serve_applied: AtomicU64,
    /// Connect listeners not yet picked up by the stack.
    new_connects: Mutex<Vec<(TcpListener, Ipv6Addr)>>,
    /// Loopback port per peer, so a second ask for the same peer reuses it.
    connect_ports: Mutex<HashMap<Ipv6Addr, u16>>,
    stop: AtomicBool,
    /// Sockets the stack holds, listeners included; a leak shows up here.
    sockets: AtomicU64,
    pub counters: Counters,
}

impl Control {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    /// Returns once the running stack listens (or has cut and stopped
    /// listening), so a friend dialling right after sharing is turned on is
    /// not reset. Waits at most 2 s; false if the stack never applied it (it
    /// is not running).
    pub fn set_serve(&self, forward: Option<SocketAddr>) -> bool {
        let want = {
            let mut serve = self.serve.lock().unwrap();
            *serve = forward;
            self.serve_gen.fetch_add(1, Ordering::SeqCst) + 1
        };
        let end = std::time::Instant::now() + Duration::from_secs(2);
        while self.serve_applied.load(Ordering::SeqCst) < want
            && !self.stop.load(Ordering::SeqCst)
            && std::time::Instant::now() < end
        {
            std::thread::sleep(Duration::from_millis(1));
        }
        self.serve_applied.load(Ordering::SeqCst) >= want
    }

    /// The forward and the generation it belongs to, read together.
    fn serve_now(&self) -> (Option<SocketAddr>, u64) {
        let serve = self.serve.lock().unwrap();
        (*serve, self.serve_gen.load(Ordering::SeqCst))
    }

    /// Splice connections accepted on `listener` to `peer`:MESH_PORT.
    pub fn add_connect(&self, listener: TcpListener, peer: Ipv6Addr) -> Result<u16> {
        listener.set_nonblocking(true)?;
        let port = listener.local_addr()?.port();
        self.connect_ports.lock().unwrap().insert(peer, port);
        self.new_connects.lock().unwrap().push((listener, peer));
        Ok(port)
    }

    /// A loopback port that reaches `peer`:MESH_PORT, opening one if needed.
    pub fn connect_port(&self, peer: Ipv6Addr) -> Result<u16> {
        if let Some(port) = self.connect_ports.lock().unwrap().get(&peer) {
            return Ok(*port);
        }
        let listener = TcpListener::bind(("127.0.0.1", 0)).context("bind loopback")?;
        self.add_connect(listener, peer)
    }

    pub fn connect_ports(&self) -> Vec<(Ipv6Addr, u16)> {
        self.connect_ports.lock().unwrap().iter().map(|(a, p)| (*a, *p)).collect()
    }

    pub fn socket_count(&self) -> u64 {
        self.sockets.load(Ordering::Relaxed)
    }

    /// Ends `run`: every connection is reset and the thread returns.
    pub fn stop(&self) {
        self.stop.store(true, Ordering::SeqCst);
    }
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
    kind: Kind,
    /// mesh -> local bytes the local stream has not accepted yet.
    pending: Vec<u8>,
    local_eof: bool,
    local_shut: bool,
}

impl Splice {
    fn new(handle: SocketHandle, stream: TcpStream, kind: Kind) -> Self {
        Self { handle, stream, kind, pending: Vec::new(), local_eof: false, local_shut: false }
    }
}

/// How long a read waits for a friend to answer before the local client is
/// reset. Without it a SYN to an offline friend retries forever and the
/// splice never ends.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(if cfg!(test) { 1 } else { 20 });
/// Keep-alive probes an idle connection; one that hears nothing back for
/// IDLE_TIMEOUT is reset, so a friend who vanishes without a FIN or RST does
/// not hold a splice open. Keep-alive only probes; the timeout does the cut.
const KEEP_ALIVE: Duration = Duration::from_secs(if cfg!(test) { 1 } else { 20 });
const IDLE_TIMEOUT: Duration = Duration::from_secs(if cfg!(test) { 3 } else { 60 });

/// A local stream ready to splice: non-blocking, no Nagle.
fn local_ready(stream: &TcpStream) -> std::io::Result<()> {
    stream.set_nonblocking(true)?;
    stream.set_nodelay(true)
}

fn new_socket() -> tcp::Socket<'static> {
    let mut s = tcp::Socket::new(
        tcp::SocketBuffer::new(vec![0; 256 * 1024]),
        tcp::SocketBuffer::new(vec![0; 256 * 1024]),
    );
    s.set_nagle_enabled(false);
    s.set_keep_alive(Some(KEEP_ALIVE.into()));
    s.set_timeout(Some(IDLE_TIMEOUT.into()));
    s
}

/// Run one mode until the process ends (the probe binary).
pub fn run(
    my_addr: Ipv6Addr,
    mtu: usize,
    to_mesh: TunOutboundTx,
    from_mesh: Receiver<Vec<u8>>,
    mode: Mode,
) -> Result<()> {
    let ctl = Control::new();
    match mode {
        Mode::Serve { forward } => {
            println!("serving mesh [{my_addr}]:{MESH_PORT} -> {forward}");
            *ctl.serve.lock().unwrap() = Some(forward);
        }
        Mode::Connect { listen, peer } => {
            let l = TcpListener::bind(listen).with_context(|| format!("bind {listen}"))?;
            println!("listening on {listen} -> peer [..]:{MESH_PORT}");
            ctl.add_connect(l, peer)?;
        }
    }
    run_with(my_addr, mtu, to_mesh, from_mesh, &ctl)
}

/// Serve and connect on one TUN, as `ctl` says, until `ctl.stop()`.
pub fn run_with(
    my_addr: Ipv6Addr,
    mtu: usize,
    to_mesh: TunOutboundTx,
    from_mesh: Receiver<Vec<u8>>,
    ctl: &Control,
) -> Result<()> {
    let mut dev = ChannelDevice { to_mesh, from_mesh, mtu, rx_queue: VecDeque::new() };
    let mut iface = Interface::new(Config::new(HardwareAddress::Ip), &mut dev, Instant::now());
    iface.update_ip_addrs(|a| {
        // /8 makes all of fd::/8 on-link; Medium::Ip has no neighbour step.
        let _ = a.push(IpCidr::new(IpAddress::Ipv6(Ipv6Address::from(my_addr)), 8));
    });

    let mut sockets = SocketSet::new(vec![]);
    let mut listeners: Vec<SocketHandle> = Vec::new();
    let mut connects: Vec<(TcpListener, Ipv6Addr)> = Vec::new();
    let mut splices: Vec<Splice> = Vec::new();
    // Aborted sockets, kept for one poll so their RST goes out.
    let mut dying: Vec<SocketHandle> = Vec::new();
    let mut next_port: u16 = 49152;
    let c = &ctl.counters;

    let mut buf = vec![0u8; 64 * 1024];
    loop {
        let stopping = ctl.stop.load(Ordering::SeqCst);
        let (serve, generation) = ctl.serve_now();
        let serve = if stopping { None } else { serve };

        if serve.is_none() {
            // Sharing off: stop listening, and cut what is being served.
            for h in listeners.drain(..) {
                sockets.get_mut::<tcp::Socket>(h).abort();
                dying.push(h);
            }
            splices.retain(|sp| {
                if sp.kind != Kind::Served && !stopping {
                    return true;
                }
                sockets.get_mut::<tcp::Socket>(sp.handle).abort();
                let _ = socket2::SockRef::from(&sp.stream).set_linger(Some(Duration::ZERO));
                dying.push(sp.handle);
                false
            });
        }
        if serve.is_some() {
            // Keep a few listeners armed; smoltcp listens one-per-socket.
            // Armed before the poll, so a SYN in this poll finds one.
            while listeners.len() < 4 {
                let mut s = new_socket();
                s.listen(MESH_PORT)?;
                listeners.push(sockets.add(s));
            }
        }
        ctl.serve_applied.store(generation, Ordering::SeqCst);
        if stopping {
            connects.clear();
            ctl.connect_ports.lock().unwrap().clear();
        } else {
            connects.append(&mut ctl.new_connects.lock().unwrap());
        }

        let now = Instant::now();
        iface.poll(now, &mut dev, &mut sockets);
        for h in dying.drain(..) {
            sockets.remove(h);
        }
        if stopping {
            c.served_open.store(0, Ordering::Relaxed);
            c.read_open.store(0, Ordering::Relaxed);
            return Ok(());
        }
        let mut busy = false;

        if let Some(forward) = serve {
            let mut i = 0;
            while i < listeners.len() {
                let h = listeners[i];
                let s = sockets.get_mut::<tcp::Socket>(h);
                if s.is_active() {
                    listeners.swap_remove(i);
                    let remote = s.remote_endpoint();
                    let local = TcpStream::connect_timeout(&forward, Duration::from_secs(3))
                        .and_then(|stream| local_ready(&stream).map(|()| stream));
                    match local {
                        Ok(stream) => {
                            println!("mesh accept {remote:?} -> {forward}");
                            c.served_total.fetch_add(1, Ordering::Relaxed);
                            splices.push(Splice::new(h, stream, Kind::Served));
                        }
                        Err(e) => {
                            eprintln!("forward {forward} failed: {e}");
                            s.abort();
                            dying.push(h);
                        }
                    }
                    busy = true;
                } else {
                    i += 1;
                }
            }
        }

        for (l, peer) in &connects {
            while let Ok((stream, from)) = l.accept() {
                // A failure here costs this one connection (the local client
                // sees it closed), never the stack.
                if let Err(e) = local_ready(&stream) {
                    eprintln!("local accept {from}: {e}");
                    continue;
                }
                let mut s = new_socket();
                s.set_timeout(Some(CONNECT_TIMEOUT.into()));
                next_port = if next_port == u16::MAX { 49152 } else { next_port + 1 };
                let to = (IpAddress::Ipv6(Ipv6Address::from(*peer)), MESH_PORT);
                if let Err(e) = s.connect(iface.context(), to, next_port) {
                    eprintln!("mesh connect [{peer}]: {e}");
                    continue;
                }
                println!("local accept {from} -> mesh [{peer}]:{MESH_PORT}");
                c.read_total.fetch_add(1, Ordering::Relaxed);
                splices.push(Splice::new(sockets.add(s), stream, Kind::Read));
                busy = true;
            }
        }

        splices.retain_mut(|sp| {
            let s = sockets.get_mut::<tcp::Socket>(sp.handle);
            if sp.kind == Kind::Read && s.may_send() && s.timeout() != Some(IDLE_TIMEOUT.into()) {
                // Connected: from here the idle timeout decides when a friend is gone.
                s.set_timeout(Some(IDLE_TIMEOUT.into()));
            }
            let (rx, tx) = match sp.kind {
                Kind::Served => (&c.served_rx, &c.served_tx),
                Kind::Read => (&c.read_rx, &c.read_tx),
            };

            // mesh -> local
            if sp.pending.is_empty() && s.can_recv() {
                if let Ok(n) = s.recv_slice(&mut buf) {
                    sp.pending.extend_from_slice(&buf[..n]);
                    rx.fetch_add(n as u64, Ordering::Relaxed);
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
                        sp.pending.clear();
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
                        tx.fetch_add(n as u64, Ordering::Relaxed);
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

            // smoltcp keeps received bytes readable after Closed/TimeWait, so a
            // splice lives until they have reached the local stream too.
            let ended = matches!(s.state(), tcp::State::Closed | tcp::State::TimeWait);
            let done = ended && !s.can_recv() && sp.pending.is_empty();
            if done {
                if !sp.local_shut {
                    // Closed without the peer's FIN (RST or timeout): reset the
                    // local client so a cut-off body is an error, not a clean EOF.
                    let _ = socket2::SockRef::from(&sp.stream).set_linger(Some(Duration::ZERO));
                }
                sockets.remove(sp.handle);
            }
            !done
        });

        let served = splices.iter().filter(|sp| sp.kind == Kind::Served).count();
        c.served_open.store(served as u64, Ordering::Relaxed);
        c.read_open.store((splices.len() - served) as u64, Ordering::Relaxed);
        ctl.sockets.store(sockets.iter().count() as u64, Ordering::Relaxed);

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
