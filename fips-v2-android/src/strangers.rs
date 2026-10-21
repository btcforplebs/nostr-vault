//! Strangers on an own-devices node (the Mac app, Logen 2026-10-21): one
//! node, no separate photo node.
//!
//! Own devices keep their stack and reach the shared relay port uncapped.
//! Everyone else's packets go to a second stack on the same address, whose
//! mesh connections are spliced to the stranger door, not to the relay:
//! - the door holds at most [`STRANGER_SLOTS`] stranger connections at once,
//!   and turns the next one away, so strangers never take a slot from My
//!   Devices (theirs are in the other stack);
//! - all strangers together move at most [`STRANGER_RATE`] bytes/s, both
//!   directions counted;
//! - each stranger has the visitor caps an open phone has
//!   ([`stack::ServeLimits`]).
//!
//! Past the door a stranger reaches the relay port the same way an https
//! visitor through a tunnel does, from 127.0.0.1, and Haven decides what it
//! may read or write: owner and whitelist by NIP-42 and signatures, never by
//! the loopback address. Strangers reach this node through the public seeds;
//! traversal offers stay own-devices-only, so they never learn its address.

use std::io::{ErrorKind, Read, Write};
use std::net::{Ipv6Addr, Shutdown, SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicU16, AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc::Receiver;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use fips::upper::tun::TunOutboundTx;

use crate::stack;

/// Bytes/s for all strangers together, both directions: 1 MiB/s, a slice of
/// a home uplink (the helper's `--blob-rate` default).
pub const STRANGER_RATE: u64 = 1 << 20;
/// Stranger connections the door holds at once.
pub const STRANGER_SLOTS: usize = 16;

/// What one stranger may pull per sharing session, and hold open at once.
const PER_STRANGER_BYTES: u64 = 256 << 20;
const PER_STRANGER_OPEN: usize = 6;
// One stranger cannot fill the door.
const _: () = assert!(PER_STRANGER_OPEN < STRANGER_SLOTS);
/// How long the door waits for the relay to take a connection.
const RELAY_CONNECT: Duration = Duration::from_secs(3);

pub fn limits() -> stack::ServeLimits {
    // No total: the rate cap bounds it, and a total would turn strangers off
    // for good on a Mac that shares for days.
    stack::ServeLimits { total_bytes: 0, per_peer_bytes: PER_STRANGER_BYTES, per_peer_open: PER_STRANGER_OPEN }
}

/// Strangers' counters, for `status_json`.
#[derive(Default)]
pub struct Counters {
    pub open: AtomicUsize,
    pub total: AtomicU64,
    /// Turned away: door full, or sharing off.
    pub refused: AtomicU64,
    /// Bytes to strangers and from them, through the door.
    pub tx: AtomicU64,
    pub rx: AtomicU64,
}

/// The strangers' stack and door, while the node runs.
pub struct Strangers {
    pub ctl: Arc<stack::Control>,
    pub counters: Arc<Counters>,
    door: SocketAddr,
    /// The relay port the door forwards to; 0 while sharing is off.
    relay_port: Arc<AtomicU16>,
    stop: Arc<AtomicBool>,
    stack_thread: std::thread::JoinHandle<()>,
    door_thread: std::thread::JoinHandle<()>,
}

impl Strangers {
    pub fn start(address: Ipv6Addr, mtu: usize, to_mesh: TunOutboundTx, from_mesh: Receiver<Vec<u8>>) -> Result<Self> {
        Self::start_with(address, mtu, to_mesh, from_mesh, STRANGER_RATE, STRANGER_SLOTS)
    }

    fn start_with(
        address: Ipv6Addr,
        mtu: usize,
        to_mesh: TunOutboundTx,
        from_mesh: Receiver<Vec<u8>>,
        rate: u64,
        slots: usize,
    ) -> Result<Self> {
        let listener = TcpListener::bind(("127.0.0.1", 0)).context("bind stranger door")?;
        let door = listener.local_addr()?;
        let relay_port = Arc::new(AtomicU16::new(0));
        let stop = Arc::new(AtomicBool::new(false));
        let counters = Arc::new(Counters::default());
        let gate = Door { relay_port: relay_port.clone(), stop: stop.clone(), counters: counters.clone(), bucket: Bucket::new(rate), slots };
        let door_thread = std::thread::Builder::new()
            .name("fips-stranger-door".into())
            .spawn(move || gate.run(listener))?;
        let ctl = stack::Control::new();
        ctl.set_limits(limits());
        let stack_ctl = ctl.clone();
        let stack_thread = std::thread::Builder::new().name("fips-stranger-stack".into()).spawn(move || {
            if let Err(e) = stack::run_with(address, mtu, to_mesh, from_mesh, &stack_ctl) {
                tracing::warn!("stranger stack stopped: {e:#}");
            }
        });
        let stack_thread = match stack_thread {
            Ok(t) => t,
            Err(e) => {
                stop.store(true, Ordering::SeqCst);
                let _ = TcpStream::connect(door);
                let _ = door_thread.join();
                return Err(e.into());
            }
        };
        Ok(Self { ctl, counters, door, relay_port, stop, stack_thread, door_thread })
    }

    /// Let strangers through to `port`, or (`None`) cut them and turn them away.
    pub fn share(&self, port: Option<u16>) -> bool {
        self.relay_port.store(port.unwrap_or(0), Ordering::SeqCst);
        self.ctl.set_serve(port.map(|_| self.door))
    }

    pub fn stop(self) {
        self.ctl.stop();
        let _ = self.stack_thread.join();
        self.stop.store(true, Ordering::SeqCst);
        // Wakes the blocking accept.
        let _ = TcpStream::connect(self.door);
        let _ = self.door_thread.join();
    }
}

struct Door {
    relay_port: Arc<AtomicU16>,
    stop: Arc<AtomicBool>,
    counters: Arc<Counters>,
    bucket: Arc<Bucket>,
    slots: usize,
}

impl Door {
    fn run(self, listener: TcpListener) {
        for stream in listener.incoming() {
            if self.stop.load(Ordering::SeqCst) {
                return;
            }
            let Ok(stranger) = stream else { continue };
            // Anything else on this Mac that finds the door reaches only
            // what it could reach on the relay port directly.
            let port = self.relay_port.load(Ordering::SeqCst);
            let c = &self.counters;
            if port == 0 || c.open.load(Ordering::SeqCst) >= self.slots {
                c.refused.fetch_add(1, Ordering::Relaxed);
                println!("stranger refused: {}", if port == 0 { "sharing off" } else { "door full" });
                let _ = stranger.shutdown(Shutdown::Both);
                continue;
            }
            let relay = SocketAddr::from(([127, 0, 0, 1], port));
            let relay = match TcpStream::connect_timeout(&relay, RELAY_CONNECT) {
                Ok(r) => r,
                Err(e) => {
                    eprintln!("stranger door: relay {relay}: {e}");
                    let _ = stranger.shutdown(Shutdown::Both);
                    continue;
                }
            };
            c.open.fetch_add(1, Ordering::SeqCst);
            c.total.fetch_add(1, Ordering::Relaxed);
            let (counters, bucket) = (self.counters.clone(), self.bucket.clone());
            let spawned = std::thread::Builder::new()
                .name("fips-stranger".into())
                .spawn(move || splice(stranger, relay, &bucket, &counters));
            if spawned.is_err() {
                self.counters.open.fetch_sub(1, Ordering::SeqCst);
            }
        }
    }
}

/// Both directions through the bucket, until either side ends; then both close.
fn splice(stranger: TcpStream, relay: TcpStream, bucket: &Arc<Bucket>, c: &Arc<Counters>) {
    let pair = stranger.try_clone().and_then(|s| relay.try_clone().map(|r| (s, r)));
    if let Ok((stranger2, relay2)) = pair {
        let (b, c2) = (bucket.clone(), c.clone());
        let up = std::thread::Builder::new()
            .name("fips-stranger-up".into())
            .spawn(move || pump(stranger2, relay2, &b, &c2.rx));
        pump(relay, stranger, bucket, &c.tx);
        if let Ok(up) = up {
            let _ = up.join();
        }
    }
    c.open.fetch_sub(1, Ordering::SeqCst);
}

/// Copy `from` to `to` at the bucket's pace. On the end of either, shut both
/// down, which also ends the other direction.
fn pump(mut from: TcpStream, mut to: TcpStream, bucket: &Bucket, count: &AtomicU64) {
    let mut buf = vec![0u8; 16 * 1024];
    loop {
        let n = match from.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) if e.kind() == ErrorKind::Interrupted => continue,
            Err(_) => break,
        };
        bucket.take(n);
        if to.write_all(&buf[..n]).is_err() {
            break;
        }
        count.fetch_add(n as u64, Ordering::Relaxed);
    }
    let _ = from.shutdown(Shutdown::Both);
    let _ = to.shutdown(Shutdown::Both);
}

/// A token bucket shared by every stranger connection (fips-v2's blob gate).
struct Bucket {
    rate: u64,
    /// Bytes that may go out now (at most one second's worth), and when.
    state: Mutex<(f64, Instant)>,
}

impl Bucket {
    fn new(rate: u64) -> Arc<Self> {
        Arc::new(Self { rate, state: Mutex::new((rate as f64, Instant::now())) })
    }

    /// Wait until `n` bytes may go out, and take them.
    fn take(&self, n: usize) {
        if self.rate == 0 {
            return;
        }
        let rate = self.rate as f64;
        let wait = {
            let mut st = self.state.lock().unwrap_or_else(|e| e.into_inner());
            let now = Instant::now();
            let tokens = (st.0 + now.duration_since(st.1).as_secs_f64() * rate).min(rate) - n as f64;
            *st = (tokens, now);
            // In debt: this caller sleeps it off; the next one starts deeper.
            if tokens < 0.0 { -tokens / rate } else { 0.0 }
        };
        std::thread::sleep(Duration::from_secs_f64(wait));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A relay stand-in: echoes, or (`send`) writes that many bytes and closes.
    fn relay(send: Option<usize>) -> (u16, std::thread::JoinHandle<()>) {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = l.local_addr().unwrap().port();
        let t = std::thread::spawn(move || {
            for s in l.incoming() {
                let Ok(mut s) = s else { return };
                std::thread::spawn(move || match send {
                    Some(n) => {
                        let _ = s.write_all(&vec![7u8; n]);
                    }
                    None => {
                        let mut b = [0u8; 1024];
                        while let Ok(n) = s.read(&mut b) {
                            if n == 0 || s.write_all(&b[..n]).is_err() {
                                break;
                            }
                        }
                    }
                });
            }
        });
        (port, t)
    }

    fn door(rate: u64, slots: usize, port: u16) -> (SocketAddr, Arc<Counters>, Arc<AtomicU16>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let counters = Arc::new(Counters::default());
        let relay_port = Arc::new(AtomicU16::new(port));
        let d = Door {
            relay_port: relay_port.clone(),
            stop: Arc::new(AtomicBool::new(false)),
            counters: counters.clone(),
            bucket: Bucket::new(rate),
            slots,
        };
        std::thread::spawn(move || d.run(listener));
        (addr, counters, relay_port)
    }

    fn wait_for(f: impl Fn() -> bool) {
        let end = Instant::now() + Duration::from_secs(5);
        while !f() {
            assert!(Instant::now() < end, "timed out");
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn the_door_forwards_and_counts() {
        let (port, _r) = relay(None);
        let (addr, c, _) = door(0, 4, port);
        let mut s = TcpStream::connect(addr).unwrap();
        s.write_all(b"hello").unwrap();
        let mut got = [0u8; 5];
        s.read_exact(&mut got).unwrap();
        assert_eq!(&got, b"hello");
        drop(s);
        wait_for(|| c.open.load(Ordering::SeqCst) == 0);
        assert_eq!(c.total.load(Ordering::SeqCst), 1);
        assert_eq!(c.rx.load(Ordering::SeqCst), 5);
        assert_eq!(c.tx.load(Ordering::SeqCst), 5);
    }

    #[test]
    fn a_full_door_turns_the_next_stranger_away() {
        let (port, _r) = relay(None);
        let (addr, c, _) = door(0, 2, port);
        let held: Vec<_> = (0..2).map(|_| TcpStream::connect(addr).unwrap()).collect();
        wait_for(|| c.open.load(Ordering::SeqCst) == 2);
        let mut third = TcpStream::connect(addr).unwrap();
        third.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
        let _ = third.write_all(b"x");
        let mut b = [0u8; 1];
        assert!(matches!(third.read(&mut b), Ok(0) | Err(_)), "closed, never echoed");
        assert_eq!(c.refused.load(Ordering::SeqCst), 1);
        // A slot frees when a stranger leaves.
        drop(held);
        wait_for(|| c.open.load(Ordering::SeqCst) == 0);
        let mut again = TcpStream::connect(addr).unwrap();
        again.write_all(b"y").unwrap();
        again.read_exact(&mut b).unwrap();
        assert_eq!(&b, b"y");
    }

    #[test]
    fn sharing_off_turns_strangers_away() {
        let (port, _r) = relay(None);
        let (addr, c, relay_port) = door(0, 4, port);
        relay_port.store(0, Ordering::SeqCst);
        let mut s = TcpStream::connect(addr).unwrap();
        s.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
        let mut b = [0u8; 1];
        assert!(matches!(s.read(&mut b), Ok(0) | Err(_)));
        assert_eq!(c.refused.load(Ordering::SeqCst), 1);
        assert_eq!(c.total.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn strangers_together_stay_under_the_rate() {
        // 64 KiB/s, a 64 KiB burst: 192 KiB to two strangers takes >= ~2 s.
        let rate = 64 * 1024;
        let (port, _r) = relay(Some(96 * 1024));
        let (addr, _c, _) = door(rate, 4, port);
        let start = Instant::now();
        let readers: Vec<_> = (0..2)
            .map(|_| {
                std::thread::spawn(move || {
                    let mut s = TcpStream::connect(addr).unwrap();
                    let mut all = Vec::new();
                    s.read_to_end(&mut all).unwrap();
                    all.len()
                })
            })
            .collect();
        let total: usize = readers.into_iter().map(|t| t.join().unwrap()).sum();
        assert_eq!(total, 192 * 1024);
        let took = start.elapsed();
        assert!(took >= Duration::from_millis(1800), "took {took:?}");
    }

    /// Mesh to relay: a stranger's connection is served by the strangers'
    /// stack through the door, and the owner's stack never sees it.
    #[test]
    fn a_stranger_reaches_the_relay_only_through_the_door() {
        use std::collections::HashSet;
        let me: Ipv6Addr = "fd00::a".parse().unwrap();
        let own_dev: Ipv6Addr = "fd00::c".parse().unwrap();
        let stranger: Ipv6Addr = "fd00::b".parse().unwrap();
        let (port, _r) = relay(None);

        // This node: the filter, the owner's stack, and the strangers' side.
        let (me_out, mut me_out_rx) = tokio::sync::mpsc::channel::<Vec<u8>>(1024);
        let (mesh_tx, mesh_rx) = std::sync::mpsc::channel();
        let (own_tx, own_rx) = std::sync::mpsc::channel();
        let (str_tx, str_rx) = std::sync::mpsc::channel();
        let side = Strangers::start(me, 1280, me_out.clone(), str_rx).unwrap();
        std::thread::spawn(move || crate::own_devices::filter(mesh_rx, me, HashSet::from([own_dev]), own_tx, Some(str_tx)));
        let own_ctl = stack::Control::new();
        let c = own_ctl.clone();
        std::thread::spawn(move || stack::run_with(me, 1280, me_out, own_rx, &c));
        assert!(own_ctl.set_serve(Some(SocketAddr::from(([127, 0, 0, 1], port)))));
        assert!(side.share(Some(port)));

        // The stranger, wired to this node both ways.
        let (s_out, mut s_out_rx) = tokio::sync::mpsc::channel::<Vec<u8>>(1024);
        let (s_in_tx, s_in) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            while let Some(p) = s_out_rx.blocking_recv() {
                let _ = mesh_tx.send(p);
            }
        });
        std::thread::spawn(move || {
            while let Some(p) = me_out_rx.blocking_recv() {
                let _ = s_in_tx.send(p);
            }
        });
        let s_ctl = stack::Control::new();
        let c = s_ctl.clone();
        std::thread::spawn(move || stack::run_with(stranger, 1280, s_out, s_in, &c));
        let local = TcpListener::bind("127.0.0.1:0").unwrap();
        let reader = s_ctl.add_connect(local, me, None).unwrap();

        let mut conn = TcpStream::connect(("127.0.0.1", reader.port)).unwrap();
        conn.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        conn.write_all(b"GET / HTTP/1.1\r\n\r\n").unwrap();
        let mut got = [0u8; 18];
        conn.read_exact(&mut got).unwrap();
        assert_eq!(&got, b"GET / HTTP/1.1\r\n\r\n");
        assert_eq!(side.counters.total.load(Ordering::SeqCst), 1, "served through the door");
        assert_eq!(own_ctl.counters.served_total.load(Ordering::SeqCst), 0, "never by the owner's stack");

        // Sharing off: the stranger gets nothing more.
        drop(conn);
        assert!(side.share(None));
        let mut again = TcpStream::connect(("127.0.0.1", reader.port)).unwrap();
        again.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
        let _ = again.write_all(b"GET / HTTP/1.1\r\n\r\n");
        let mut b = [0u8; 1];
        assert!(matches!(again.read(&mut b), Ok(0) | Err(_)));
        s_ctl.stop();
        own_ctl.stop();
        side.stop();
    }

    #[test]
    fn strangers_have_visitor_caps_and_no_total() {
        let l = limits();
        assert_eq!(l.total_bytes, 0);
        assert!(l.per_peer_bytes > 0 && l.per_peer_open > 0);
    }
}
