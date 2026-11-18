import { test } from "node:test"
import assert from "node:assert/strict"
import { query, queryPaged, queryRelays, closeAll } from "../nostr.mjs"

// A fake relay socket: answers each REQ with the stored notes the filter matches (newest first, up to limit), then EOSE.
function fakeRelay(notes, { eose = true } = {}) {
  const reqs = []
  class FakeSocket {
    constructor() { setTimeout(() => this.onopen?.(), 0) }
    send(text) {
      const [type, sub, f] = JSON.parse(text)
      if (type !== "REQ") return
      reqs.push(f)
      const hits = notes.filter(n => (!f.until || n.created_at <= f.until) && (!f.since || n.created_at >= f.since))
        .sort((a, b) => b.created_at - a.created_at).slice(0, f.limit ?? 500)
      setTimeout(() => {
        for (const n of hits) this.onmessage?.({ data: JSON.stringify(["EVENT", sub, n]) })
        if (eose) this.onmessage?.({ data: JSON.stringify(["EOSE", sub]) })
      }, 0)
    }
    close() {}
  }
  return { FakeSocket, reqs }
}

const notes = n => Array.from({ length: n }, (_, i) => ({ id: "e" + i, pubkey: "p", kind: 1, created_at: 1000 + i, tags: [] }))

test("query collects events until EOSE", async () => {
  const { FakeSocket } = fakeRelay(notes(3))
  const res = await query("wss://x", { kinds: [1] }, { WebSocketImpl: FakeSocket })
  assert.equal(res.ok, true)
  assert.equal(res.events.length, 3)
})

test("query without EOSE times out as not ok", async () => {
  const { FakeSocket } = fakeRelay(notes(2), { eose: false })
  const res = await query("wss://x", {}, { WebSocketImpl: FakeSocket, timeoutMs: 30 })
  assert.equal(res.ok, false)
  assert.equal(res.events.length, 2)
})

test("queryPaged walks back with until and reads every note once", async () => {
  const { FakeSocket, reqs } = fakeRelay(notes(25))
  const res = await queryPaged("wss://x", { kinds: [1] }, { WebSocketImpl: FakeSocket, pageSize: 10 })
  assert.equal(new Set(res.events.map(e => e.id)).size, 25)
  assert.equal(res.events.length, 25)
  assert.equal(res.capped, false)
  assert.deepEqual(reqs.map(r => r.until), [undefined, 1014, 1004, 999])
})

test("queryPaged reports capped when notes remain past maxPages", async () => {
  const { FakeSocket } = fakeRelay(notes(25))
  const res = await queryPaged("wss://x", { kinds: [1] }, { WebSocketImpl: FakeSocket, pageSize: 10, maxPages: 2 })
  assert.equal(res.events.length, 20)
  assert.equal(res.capped, true)
})

test("queryRelays names the relays that answered and the ones that were capped", async () => {
  const good = fakeRelay(notes(5)).FakeSocket
  const res = await queryRelays(["wss://a"], { kinds: [1] }, { WebSocketImpl: good, pageSize: 2, maxPages: 1 })
  assert.deepEqual(res.answered, ["wss://a"])
  assert.deepEqual(res.capped, ["wss://a"])
})

test("query sends a User-Agent (relay.damus.io refuses the handshake without one)", async () => {
  let opts
  const { FakeSocket } = fakeRelay(notes(1))
  class Spy extends FakeSocket { constructor(url, o) { super(); opts = o } }
  await query("wss://x", {}, { WebSocketImpl: Spy })
  assert.match(opts?.headers?.["user-agent"] ?? "", /nostrvault-stats/)
})

test("queries to one relay share one socket", async () => {
  let opened = 0
  const { FakeSocket } = fakeRelay(notes(25))
  class Counting extends FakeSocket { constructor() { super(); opened++ } }
  const res = await queryPaged("wss://x", { kinds: [1] }, { WebSocketImpl: Counting, pageSize: 10 })
  assert.equal(res.events.length, 25)
  assert.equal(opened, 1)
  closeAll(Counting)
})

test("a dropped socket fails its query and the next query opens a new one", async () => {
  let opened = 0
  const { FakeSocket } = fakeRelay(notes(1), { eose: false })
  class Dropping extends FakeSocket { constructor() { super(); opened++ } }
  const first = await query("wss://y", {}, { WebSocketImpl: Dropping, timeoutMs: 20 })
  assert.equal(first.ok, false)
  await query("wss://y", {}, { WebSocketImpl: Dropping, timeoutMs: 20 })
  assert.equal(opened, 2)
  closeAll(Dropping)
})

test("a failed query says why: a relay's CLOSED message, or a timeout", async () => {
  class Closing {
    constructor() { setTimeout(() => this.onopen?.(), 0) }
    send(text) { const [type, sub] = JSON.parse(text); if (type === "REQ") setTimeout(() => this.onmessage?.({ data: JSON.stringify(["CLOSED", sub, "rate-limited: slow down"]) }), 0) }
    close() {}
  }
  const closed = await query("wss://c", {}, { WebSocketImpl: Closing })
  assert.equal(closed.why, "CLOSED rate-limited: slow down")
  const res = await queryRelays(["wss://c"], {}, { WebSocketImpl: Closing })
  assert.deepEqual(res.why, { "wss://c": "CLOSED rate-limited: slow down" })
  closeAll(Closing)
  const { FakeSocket } = fakeRelay(notes(1), { eose: false })
  assert.equal((await query("wss://t", {}, { WebSocketImpl: FakeSocket, timeoutMs: 20 })).why, "timeout")
  closeAll(FakeSocket)
})

test("a page whose socket drops is asked once more on a fresh socket", async () => {
  let opened = 0
  const all = notes(3)
  class DropFirst {
    constructor() { this.n = ++opened; setTimeout(() => this.onopen?.(), 0) }
    send(text) {
      const [type, sub, f] = JSON.parse(text)
      if (type !== "REQ") return
      // The first socket dies before answering; the second answers in full.
      if (this.n === 1) return setTimeout(() => this.onclose?.(), 0)
      const hits = all.filter(n => !f.until || n.created_at <= f.until)
      setTimeout(() => { for (const n of hits) this.onmessage?.({ data: JSON.stringify(["EVENT", sub, n]) }); this.onmessage?.({ data: JSON.stringify(["EOSE", sub]) }) }, 0)
    }
    close() {}
  }
  const res = await queryPaged("wss://d", { kinds: [1] }, { WebSocketImpl: DropFirst, pageSize: 10 })
  assert.equal(res.ok, true)
  assert.equal(res.events.length, 3)
  assert.equal(opened, 2)
  closeAll(DropFirst)
  opened = 0
  const noRetry = await queryPaged("wss://e", { kinds: [1] }, { WebSocketImpl: DropFirst, pageSize: 10, retry: false })
  assert.equal(noRetry.ok, false, "positive control: without the retry the drop loses the page")
  closeAll(DropFirst)
})

test("a relay that can't be reached is skipped after 3 failed connects, and closeAll forgets that", async () => {
  let tries = 0
  class Down { constructor() { tries++; setTimeout(() => this.onerror?.(), 0) } send() {} close() {} }
  const whys = []
  for (let i = 0; i < 5; i++) whys.push((await query("wss://down", {}, { WebSocketImpl: Down })).why)
  assert.equal(tries, 3)
  assert.deepEqual(whys, ["could not connect", "could not connect", "could not connect", "skipped: could not connect 3 times", "skipped: could not connect 3 times"])
  closeAll(Down)
  await query("wss://down", {}, { WebSocketImpl: Down })
  assert.equal(tries, 4)
})

test("a connect failure is not retried as a page (it would only wait twice)", async () => {
  let tries = 0
  class Down { constructor() { tries++; setTimeout(() => this.onerror?.(), 0) } send() {} close() {} }
  const res = await queryPaged("wss://down2", { kinds: [1] }, { WebSocketImpl: Down })
  assert.equal(res.ok, false)
  assert.equal(tries, 1)
  closeAll(Down)
})
