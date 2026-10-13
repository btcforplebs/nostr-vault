//! The core against an in-process TCP/FIPS NIP-01 server shaped like the page
//! (`web-relay/src/fips/tcp-server.js`): listens on 7447, drops every datagram
//! from a non-owner before the stack sees it, answers REQ with EVENT* + EOSE.
//! The link loses and reorders datagrams.

use std::cell::RefCell;
use std::collections::VecDeque;
use std::io;
use std::rc::Rc;
use std::time::Duration;

use fips_tcp::{Config, Stack};
use serde_json::{json, Value};
use web_relay_vault::client::run_req;
use web_relay_vault::link::DatagramLink;
use web_relay_vault::ndjson::{encode, LineDecoder};

const OWNER: u8 = 1;

struct Page {
    stack: Stack<u8>,
    decoder: LineDecoder,
    conn: Option<fips_tcp::ConnectionId>,
    notes: Vec<Value>,
    rejected: usize,
    now: u64,
}

impl Page {
    fn new(notes: Vec<Value>) -> Self {
        let mut stack = Stack::new(Config::default(), 7);
        stack.listen(7447).unwrap();
        Self { stack, decoder: LineDecoder::default(), conn: None, notes, rejected: 0, now: 0 }
    }

    fn input(&mut self, from: u8, bytes: &[u8]) -> Vec<Vec<u8>> {
        self.now += 5;
        if from != OWNER {
            self.rejected += 1;
            return vec![];
        }
        let _ = self.stack.input(from, bytes, self.now);
        self.tick()
    }

    fn tick(&mut self) -> Vec<Vec<u8>> {
        self.now += 5;
        self.stack.poll(self.now);
        if self.conn.is_none() {
            self.conn = self.stack.accept(7447);
        }
        if let Some(id) = self.conn {
            if let Ok(bytes) = self.stack.read(id, 65536, self.now) {
                for msg in self.decoder.push(&bytes).unwrap() {
                    if msg[0] == "REQ" {
                        let sub = msg[1].clone();
                        let want = msg[2]["ids"].as_array().cloned();
                        for n in &self.notes {
                            if want.as_ref().is_none_or(|w| w.contains(&n["id"])) {
                                let _ = self.stack.write(id, &encode(&json!(["EVENT", sub, n])), self.now);
                            }
                        }
                        let _ = self.stack.write(id, &encode(&json!(["EOSE", sub])), self.now);
                    }
                }
            }
        }
        self.stack.drain_outbound().into_iter().map(|o| o.bytes).collect()
    }
}

/// Link from one vault key to the page. Drops every `drop_every`-th datagram
/// in each direction and swaps adjacent replies.
struct Lossy {
    page: Rc<RefCell<Page>>,
    from: u8,
    inbox: VecDeque<Vec<u8>>,
    drop_every: usize,
    sent: usize,
    recvd: usize,
}

impl DatagramLink for Lossy {
    fn send(&mut self, d: &[u8]) -> io::Result<()> {
        self.sent += 1;
        if self.drop_every > 0 && self.sent % self.drop_every == 0 {
            return Ok(());
        }
        let mut replies = self.page.borrow_mut().input(self.from, d);
        if replies.len() >= 2 {
            replies.swap(0, 1);
        }
        self.inbox.extend(replies);
        Ok(())
    }

    fn recv(&mut self, _t: Duration) -> io::Result<Option<Vec<u8>>> {
        if self.inbox.is_empty() {
            let more = self.page.borrow_mut().tick();
            self.inbox.extend(more);
        }
        while let Some(d) = self.inbox.pop_front() {
            self.recvd += 1;
            if self.drop_every > 0 && self.recvd % self.drop_every == 0 {
                continue;
            }
            return Ok(Some(d));
        }
        std::thread::sleep(Duration::from_millis(2));
        Ok(None)
    }

    fn max_payload(&self) -> usize {
        1200
    }
}

fn note(i: usize, big: usize) -> Value {
    json!({ "id": format!("{i:064x}"), "kind": 1, "content": "x".repeat(big) })
}

fn link(page: &Rc<RefCell<Page>>, from: u8, drop_every: usize) -> Lossy {
    Lossy { page: page.clone(), from, inbox: VecDeque::new(), drop_every, sent: 0, recvd: 0 }
}

#[test]
fn owner_gets_every_event_then_eose_over_a_lossy_link() {
    // 30 notes of 3 KB: ~90 KB, many segments, so loss and reorder are exercised.
    let page = Rc::new(RefCell::new(Page::new((0..30).map(|i| note(i, 3000)).collect())));
    let out = run_req(&mut link(&page, OWNER, 7), "g3", json!({ "kinds": [1] }), Duration::from_secs(60)).unwrap();
    assert!(out.eose_ms.is_some(), "{out:?}");
    assert_eq!(out.events.len(), 30);
    for (i, e) in out.events.iter().enumerate() {
        assert_eq!(e["id"], json!(format!("{i:064x}")), "out of order or corrupted");
    }
}

#[test]
fn owner_req_for_one_id_gets_that_note_only() {
    let page = Rc::new(RefCell::new(Page::new((0..5).map(|i| note(i, 10)).collect())));
    let id = format!("{:064x}", 3);
    let out = run_req(&mut link(&page, OWNER, 0), "g3", json!({ "ids": [id] }), Duration::from_secs(10)).unwrap();
    assert!(out.eose_ms.is_some());
    assert_eq!(out.events.len(), 1);
    assert_eq!(out.events[0]["id"], json!(id));
}

#[test]
fn stranger_never_gets_a_syn_ack() {
    let page = Rc::new(RefCell::new(Page::new(vec![note(0, 10)])));
    let out = run_req(&mut link(&page, 2, 0), "g3", json!({}), Duration::from_secs(3)).unwrap();
    assert_eq!(out.established_ms, None);
    assert!(out.events.is_empty() && out.eose_ms.is_none());
    assert_eq!(out.datagrams_in, 0);
    assert!(page.borrow().rejected >= 1);
}
