//! Strangers on an own-devices node (the Mac app, Logen 2026-10-21): one
//! node, no separate photo node.
//!
//! Own devices keep their stack and reach the shared relay port uncapped.
//! Everyone else's packets go to a second stack on the same address, whose
//! mesh connections are spliced to the stranger door, and from there to
//! Haven's mesh door (`StartOptions::strangers_port`), never to the relay:
//! - the door holds at most [`STRANGER_SLOTS`] stranger connections at once,
//!   and turns the next one away, so strangers never take a slot from My
//!   Devices (theirs are in the other stack);
//! - all strangers together move at most [`STRANGER_RATE`] bytes/s, both
//!   directions counted;
//! - each stranger has the visitor caps an open phone has
//!   ([`stack::ServeLimits`]).
//!
//! Past the door a stranger reaches only Haven's mesh door (mesh_door.go):
//! blob reads, owner-signed uploads checked before Haven allocates, and
//! owner-signed EVENTs, with no queries and its own connection cap. The
//! relay port's other routes (/feed, blossom DELETE, the loopback rate
//! limiter bypass) are never in reach. Strangers reach this node through the public seeds;
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

/// `total`: what strangers may pull this sharing session before it stops
/// (`StartOptions::max_serve_bytes`). 0 is no total: the rate cap bounds it,
/// and a total would turn strangers off for good on a Mac that shares for
/// days. A phone passes its limit, since its data may be metered: 1 MiB/s is
/// 3.6 GB an hour (Tron, #1025).
pub fn limits(total: u64) -> stack::ServeLimits {
    // One stranger's share never exceeds the whole, as for an open phone (serve_limits).
    let per_peer_bytes = if total == 0 { PER_STRANGER_BYTES } else { PER_STRANGER_BYTES.min(total) };
    stack::ServeLimits { total_bytes: total, per_peer_bytes, per_peer_open: PER_STRANGER_OPEN }
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
    /// Haven's mesh door, where the door forwards; 0 while sharing is off.
    forward_port: Arc<AtomicU16>,
    stop: Arc<AtomicBool>,
    stack_thread: std::thread::JoinHandle<()>,
    door_thread: std::thread::JoinHandle<()>,
}

impl Strangers {
    /// `total`: see [`limits`].
    pub fn start(address: Ipv6Addr, mtu: usize, to_mesh: TunOutboundTx, from_mesh: Receiver<Vec<u8>>, total: u64) -> Result<Self> {
        Self::start_with(address, mtu, to_mesh, from_mesh, STRANGER_RATE, STRANGER_SLOTS, total)
    }

    fn start_with(
        address: Ipv6Addr,
        mtu: usize,
        to_mesh: TunOutboundTx,
        from_mesh: Receiver<Vec<u8>>,
        rate: u64,
        slots: usize,
        total: u64,
    ) -> Result<Self> {
        let listener = TcpListener::bind(("127.0.0.1", 0)).context("bind stranger door")?;
        let door = listener.local_addr()?;
        let forward_port = Arc::new(AtomicU16::new(0));
        let stop = Arc::new(AtomicBool::new(false));
        let counters = Arc::new(Counters::default());
        let gate = Door { forward_port: forward_port.clone(), stop: stop.clone(), counters: counters.clone(), bucket: Bucket::new(rate), slots };
        let door_thread = std::thread::Builder::new()
            .name("fips-stranger-door".into())
            .spawn(move || gate.run(listener))?;
        let ctl = stack::Control::new();
        ctl.set_limits(limits(total));
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
        Ok(Self { ctl, counters, door, forward_port, stop, stack_thread, door_thread })
    }

    /// Let strangers through to `port` (Haven's mesh door), or (`None`) cut
    /// them and turn them away.
    pub fn share(&self, port: Option<u16>) -> bool {
        self.forward_port.store(port.unwrap_or(0), Ordering::SeqCst);
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
    forward_port: Arc<AtomicU16>,
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
            // what it could reach on the mesh door directly.
            let port = self.forward_port.load(Ordering::SeqCst);
            let c = &self.counters;
            if port == 0 || c.open.load(Ordering::SeqCst) >= self.slots {
                c.refused.fetch_add(1, Ordering::Relaxed);
                tracing::debug!("stranger refused: {}", if port == 0 { "sharing off" } else { "door full" });
                let _ = stranger.shutdown(Shutdown::Both);
                continue;
            }
            let relay = SocketAddr::from(([127, 0, 0, 1], port));
            let relay = match TcpStream::connect_timeout(&relay, RELAY_CONNECT) {
                Ok(r) => r,
                Err(e) => {
                    tracing::warn!("stranger door: mesh door {relay}: {e}");
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
        let forward_port = Arc::new(AtomicU16::new(port));
        let d = Door {
            forward_port: forward_port.clone(),
            stop: Arc::new(AtomicBool::new(false)),
            counters: counters.clone(),
            bucket: Bucket::new(rate),
            slots,
        };
        std::thread::spawn(move || d.run(listener));
        (addr, counters, forward_port)
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
        let (addr, c, forward_port) = door(0, 4, port);
        forward_port.store(0, Ordering::SeqCst);
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

    /// A server that answers every connection with `banner` and closes.
    fn banner(banner: &'static [u8]) -> u16 {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = l.local_addr().unwrap().port();
        std::thread::spawn(move || {
            for s in l.incoming() {
                let Ok(mut s) = s else { return };
                let _ = s.write_all(banner);
            }
        });
        port
    }

    /// One end of the mesh: a stack at `addr` wired to `peer`'s packets.
    fn dial(from: Ipv6Addr, to: Ipv6Addr, mesh_in: std::sync::mpsc::Sender<Vec<u8>>, from_peer: std::sync::mpsc::Receiver<Vec<u8>>) -> (Arc<stack::Control>, u16) {
        let (out, mut out_rx) = tokio::sync::mpsc::channel::<Vec<u8>>(1024);
        std::thread::spawn(move || {
            while let Some(p) = out_rx.blocking_recv() {
                let _ = mesh_in.send(p);
            }
        });
        let ctl = stack::Control::new();
        let c = ctl.clone();
        std::thread::spawn(move || stack::run_with(from, 1280, out, from_peer, &c));
        let local = TcpListener::bind("127.0.0.1:0").unwrap();
        let reader = ctl.add_connect(local, to, None).unwrap();
        (ctl, reader.port)
    }

    fn read_all(port: u16) -> Vec<u8> {
        let mut conn = TcpStream::connect(("127.0.0.1", port)).unwrap();
        conn.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let mut got = Vec::new();
        let _ = conn.read_to_end(&mut got);
        got
    }

    /// Mesh end to end, through the split `export` makes: a stranger's
    /// connection is served by the strangers' stack, through the door, to
    /// Haven's mesh door; an own device's goes to the relay port. Neither
    /// stack sees the other's.
    #[test]
    fn strangers_reach_the_mesh_door_and_own_devices_the_relay() {
        use std::collections::HashSet;
        let me: Ipv6Addr = "fd00::a".parse().unwrap();
        let own_dev: Ipv6Addr = "fd00::c".parse().unwrap();
        let stranger: Ipv6Addr = "fd00::b".parse().unwrap();
        let relay_port = banner(b"relay");
        let mesh_door = banner(b"mesh-door");

        // This node: the filter, the owner's stack, and the strangers' side.
        let (me_out, mut me_out_rx) = tokio::sync::mpsc::channel::<Vec<u8>>(1024);
        let (mesh_tx, mesh_rx) = std::sync::mpsc::channel();
        let (own_tx, own_rx) = std::sync::mpsc::channel();
        let (str_tx, str_rx) = std::sync::mpsc::channel();
        let side = Strangers::start(me, 1280, me_out.clone(), str_rx, 0).unwrap();
        std::thread::spawn(move || crate::own_devices::filter(mesh_rx, me, HashSet::from([own_dev]), own_tx, Some(str_tx)));
        let own_ctl = stack::Control::new();
        let c = own_ctl.clone();
        std::thread::spawn(move || stack::run_with(me, 1280, me_out, own_rx, &c));
        assert!(!crate::share_split(&own_ctl, Some(&side), relay_port, relay_port), "strangers never get the relay port");
        assert!(crate::share_split(&own_ctl, Some(&side), relay_port, mesh_door));

        // This node's packets go to whichever peer they are addressed to.
        let (to_stranger, from_me_s) = std::sync::mpsc::channel();
        let (to_own, from_me_o) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            while let Some(p) = me_out_rx.blocking_recv() {
                let dst = Ipv6Addr::from(<[u8; 16]>::try_from(&p[24..40]).unwrap());
                let _ = if dst == stranger { to_stranger.send(p) } else { to_own.send(p) };
            }
        });
        let (s_ctl, s_port) = dial(stranger, me, mesh_tx.clone(), from_me_s);
        let (o_ctl, o_port) = dial(own_dev, me, mesh_tx, from_me_o);

        assert_eq!(read_all(s_port), b"mesh-door", "a stranger gets Haven's mesh door");
        assert_eq!(read_all(o_port), b"relay", "an own device gets the relay");
        assert_eq!(side.counters.total.load(Ordering::SeqCst), 1, "the stranger went through the door");
        assert_eq!(own_ctl.counters.served_total.load(Ordering::SeqCst), 1, "only the own device used the owner's stack");

        // Sharing off: the stranger gets nothing more.
        assert!(side.share(None));
        assert!(read_all(s_port).is_empty());
        s_ctl.stop();
        o_ctl.stop();
        own_ctl.stop();
        side.stop();
    }

    #[test]
    fn strangers_have_visitor_caps_and_no_total() {
        let l = limits(0);
        assert_eq!(l.total_bytes, 0);
        assert!(l.per_peer_bytes > 0 && l.per_peer_open > 0);
    }

    /// End to end: strangers who pull past a phone's limit turn their sharing
    /// off (cap_reached, which the app turns into its auto-off), while the
    /// owner's stack is untouched (Tron, #1025).
    #[test]
    fn strangers_past_the_total_turn_their_sharing_off() {
        use std::collections::HashSet;
        let me: Ipv6Addr = "fd00::a".parse().unwrap();
        let stranger: Ipv6Addr = "fd00::b".parse().unwrap();
        let blob: &'static [u8] = Box::leak(vec![b'x'; 64 * 1024].into_boxed_slice());
        let mesh_door = banner(blob);
        let relay_port = banner(b"relay");

        let (me_out, mut me_out_rx) = tokio::sync::mpsc::channel::<Vec<u8>>(1024);
        let (mesh_tx, mesh_rx) = std::sync::mpsc::channel();
        let (own_tx, own_rx) = std::sync::mpsc::channel();
        let (str_tx, str_rx) = std::sync::mpsc::channel();
        let side = Strangers::start(me, 1280, me_out.clone(), str_rx, 16 * 1024).unwrap();
        std::thread::spawn(move || crate::own_devices::filter(mesh_rx, me, HashSet::new(), own_tx, Some(str_tx)));
        let own_ctl = stack::Control::new();
        let c = own_ctl.clone();
        std::thread::spawn(move || stack::run_with(me, 1280, me_out, own_rx, &c));
        assert!(crate::share_split(&own_ctl, Some(&side), relay_port, mesh_door));
        let (to_stranger, from_me) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            while let Some(p) = me_out_rx.blocking_recv() {
                let _ = to_stranger.send(p);
            }
        });
        let (s_ctl, s_port) = dial(stranger, me, mesh_tx, from_me);

        let _ = read_all(s_port);
        let deadline = Instant::now() + Duration::from_secs(10);
        while !side.ctl.cap_reached() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(side.ctl.cap_reached(), "64 KiB to strangers is past a 16 KiB limit");
        assert!(!own_ctl.cap_reached(), "own devices have no total");
        s_ctl.stop();
        own_ctl.stop();
        side.stop();
    }

    /// A phone's limit holds for strangers (Tron, #1025): without it they had no total.
    #[test]
    fn a_phone_limit_is_the_strangers_total() {
        let l = limits(100 << 20);
        assert_eq!(l.total_bytes, 100 << 20);
        // One stranger's share never exceeds the whole.
        assert_eq!(l.per_peer_bytes, 100 << 20);
        assert_eq!(limits(1 << 30).per_peer_bytes, PER_STRANGER_BYTES);
    }
}
