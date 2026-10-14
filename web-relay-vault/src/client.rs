//! Blocking driver: run one REQ against a browser relay over any
//! [`DatagramLink`] and report what came back and when.

use std::io;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};

use crate::link::DatagramLink;
use crate::session::RelaySession;

const TICK: Duration = Duration::from_millis(50);
const CLOSE_GRACE: Duration = Duration::from_millis(1500);

#[derive(Debug, Default)]
pub struct ReqOutcome {
    /// Milliseconds from SYN to ESTABLISHED. `None`: the page never answered.
    pub established_ms: Option<u64>,
    pub events: Vec<Value>,
    /// Milliseconds from SYN to EOSE.
    pub eose_ms: Option<u64>,
    /// `["CLOSED", sub, reason]` or `["NOTICE", msg]` lines, verbatim.
    pub refusals: Vec<Value>,
    pub datagrams_out: usize,
    pub datagrams_in: usize,
    /// Set if the stream ended without EOSE (RST, retransmits spent, framing).
    pub error: Option<String>,
}

pub fn run_req<L: DatagramLink>(
    link: &mut L,
    sub_id: &str,
    filter: Value,
    deadline: Duration,
) -> io::Result<ReqOutcome> {
    let t0 = Instant::now();
    let ms = || t0.elapsed().as_millis() as u64;
    let seed = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_nanos() as u64).unwrap_or(1);
    let mut session = RelaySession::new(link.max_payload(), seed);
    let mut out = ReqOutcome::default();
    let mut req_sent = false;

    let flush = |session: &mut RelaySession, link: &mut L, out: &mut ReqOutcome| -> io::Result<()> {
        for datagram in session.outbound() {
            link.send(&datagram)?;
            out.datagrams_out += 1;
        }
        Ok(())
    };
    let fail = |e: crate::session::SessionError| io::Error::other(e.to_string());

    session.connect(ms(), seed.wrapping_mul(0x9E37_79B9_7F4A_7C15)).map_err(fail)?;
    flush(&mut session, link, &mut out)?;

    while t0.elapsed() < deadline {
        if let Some(datagram) = link.recv(TICK)? {
            out.datagrams_in += 1;
            if let Err(e) = session.on_datagram(&datagram, ms()) {
                out.error = Some(e.to_string());
                break;
            }
        }
        if let Err(e) = session.poll(ms()) {
            out.error = Some(e.to_string());
            break;
        }
        if session.is_established() && out.established_ms.is_none() {
            out.established_ms = Some(ms());
        }
        if session.is_established() && !req_sent {
            session.send(&json!(["REQ", sub_id, filter]), ms()).map_err(fail)?;
            req_sent = true;
        }
        for message in session.take_messages() {
            match message.get(0).and_then(Value::as_str) {
                Some("EVENT") if message.get(1).and_then(Value::as_str) == Some(sub_id) => {
                    out.events.push(message[2].clone())
                }
                Some("EOSE") if message.get(1).and_then(Value::as_str) == Some(sub_id) => {
                    out.eose_ms = Some(ms())
                }
                Some("CLOSED") | Some("NOTICE") => out.refusals.push(message),
                _ => {}
            }
        }
        flush(&mut session, link, &mut out)?;
        if out.eose_ms.is_some() {
            break;
        }
        if session.is_gone() {
            out.error = Some("stream dropped before EOSE".into());
            break;
        }
    }

    // Tidy close so the page frees the subscription; the result is already in.
    if session.is_established() {
        let _ = session.send(&json!(["CLOSE", sub_id]), ms());
        let _ = session.close(ms());
        let grace = Instant::now();
        while grace.elapsed() < CLOSE_GRACE && !session.is_gone() {
            flush(&mut session, link, &mut out)?;
            if let Some(datagram) = link.recv(TICK)? {
                let _ = session.on_datagram(&datagram, ms());
            }
            let _ = session.poll(ms());
        }
        flush(&mut session, link, &mut out)?;
    }
    Ok(out)
}
