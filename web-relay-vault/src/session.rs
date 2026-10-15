//! One NIP-01 stream to a browser relay, sans-I/O: datagrams in, datagrams out,
//! JSON messages in, JSON messages out. The caller owns the clock and the
//! transport.

use fips_tcp::{Config, ConnectionId, Stack, State};
use serde_json::Value;

use crate::ndjson::{self, FrameError, LineDecoder};
use crate::RELAY_SERVICE_PORT;

const READ_CHUNK: usize = 64 * 1024;

/// TCP/FIPS header plus options, kept out of the link's datagram budget.
const SEGMENT_OVERHEAD: usize = 64;

#[derive(Debug)]
pub enum SessionError {
    Tcp(String),
    Frame(FrameError),
    NotConnected,
}

impl std::fmt::Display for SessionError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Tcp(e) => write!(f, "TCP/FIPS: {e}"),
            Self::Frame(e) => write!(f, "NDJSON: {e:?}"),
            Self::NotConnected => f.write_str("no connection"),
        }
    }
}

impl std::error::Error for SessionError {}

fn tcp<E: std::fmt::Display>(e: E) -> SessionError {
    SessionError::Tcp(e.to_string())
}

pub struct RelaySession {
    // One session is one peer, so the stack's peer key carries nothing.
    stack: Stack<()>,
    id: Option<ConnectionId>,
    decoder: LineDecoder,
    pending: Vec<u8>,
    inbox: Vec<Value>,
}

impl RelaySession {
    /// `max_payload` is the link's datagram limit; the MSS is sized under it.
    pub fn new(max_payload: usize, isn_seed: u64) -> Self {
        let budget = max_payload.saturating_sub(SEGMENT_OVERHEAD).clamp(1, 1024);
        let config = Config {
            mss: budget as u16,
            ..Config::default()
        };
        Self {
            stack: Stack::new(config, isn_seed),
            id: None,
            decoder: LineDecoder::default(),
            pending: Vec::new(),
            inbox: Vec::new(),
        }
    }

    /// Send the SYN. `entropy` picks the TCP source port and ISN.
    ///
    /// Not the stack's own ephemeral allocator: it starts at 49152 in every new
    /// process, so two runs a few seconds apart reuse one 4-tuple and the second
    /// SYN lands on the page's still-closing first connection.
    pub fn connect(&mut self, now_ms: u64, entropy: u64) -> Result<(), SessionError> {
        let local_port = 49_152 + (entropy % 16_384) as u16;
        let isn = (entropy >> 16) as u32;
        let id = self
            .stack
            .connect_from_with_isn((), local_port, RELAY_SERVICE_PORT, isn, now_ms)
            .map_err(tcp)?;
        self.id = Some(id);
        Ok(())
    }

    pub fn state(&self) -> Option<State> {
        self.id.and_then(|id| self.stack.state(id))
    }

    pub fn is_established(&self) -> bool {
        self.state() == Some(State::Established)
    }

    /// The connection existed and the stack has dropped it (RST, retransmit
    /// budget spent, or a finished close).
    pub fn is_gone(&self) -> bool {
        self.id.is_some() && self.state().is_none()
    }

    /// Feed one datagram that arrived from the peer.
    pub fn on_datagram(&mut self, datagram: &[u8], now_ms: u64) -> Result<(), SessionError> {
        // A malformed segment is the peer's problem, not a reason to end ours.
        let _ = self.stack.input((), datagram, now_ms);
        self.pump(now_ms)
    }

    /// Run timers (retransmits, delayed ACKs) and move buffered bytes.
    pub fn poll(&mut self, now_ms: u64) -> Result<(), SessionError> {
        self.stack.poll(now_ms);
        self.pump(now_ms)
    }

    /// Queue one NIP-01 message on the stream.
    pub fn send(&mut self, message: &Value, now_ms: u64) -> Result<(), SessionError> {
        if self.id.is_none() {
            return Err(SessionError::NotConnected);
        }
        self.pending.extend(ndjson::encode(message));
        self.pump(now_ms)
    }

    /// Send FIN once everything queued has been handed to the stack.
    pub fn close(&mut self, now_ms: u64) -> Result<(), SessionError> {
        let id = self.id.ok_or(SessionError::NotConnected)?;
        self.pump(now_ms)?;
        if self.stack.state(id).is_some() {
            self.stack.close(id, now_ms).map_err(tcp)?;
        }
        Ok(())
    }

    /// Datagrams to hand to the link, in order.
    pub fn outbound(&mut self) -> Vec<Vec<u8>> {
        self.stack.drain_outbound().into_iter().map(|o| o.bytes).collect()
    }

    /// Messages the peer sent since the last call, in order.
    pub fn take_messages(&mut self) -> Vec<Value> {
        std::mem::take(&mut self.inbox)
    }

    fn pump(&mut self, now_ms: u64) -> Result<(), SessionError> {
        let Some(id) = self.id else { return Ok(()) };
        if self.stack.state(id).is_none() {
            return Ok(());
        }
        loop {
            let bytes = self.stack.read(id, READ_CHUNK, now_ms).map_err(tcp)?;
            if bytes.is_empty() {
                break;
            }
            let lines = self.decoder.push(&bytes).map_err(SessionError::Frame)?;
            self.inbox.extend(lines);
        }
        if !self.pending.is_empty() && self.is_established() {
            let accepted = self.stack.write(id, &self.pending, now_ms).map_err(tcp)?;
            self.pending.drain(..accepted);
        }
        Ok(())
    }
}
