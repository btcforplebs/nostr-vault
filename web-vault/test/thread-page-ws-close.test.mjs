// The public post page's relay sockets: a relay that drops the connection during the handshake must not take the
// page server down. Node 22's WebSocket fires "error" from inside close(), nostr-tools closes from onerror, and the
// two recursed until a RangeError killed the process. A fake socket with Node 22's behaviour runs on any Node; the
// real-socket case runs on whatever Node the test uses.
import test from "node:test"
import assert from "node:assert/strict"
import net from "node:net"

process.env.THREAD_PAGE_NO_LISTEN = "1"
const { closeOnce, newPool } = await import("../thread-page/server.mjs")

/** Node 22's failure path: the handshake fails, "error" fires, and close() fires "error" again before it is closed. */
class Node22Socket {
  static CONNECTING = 0; static OPEN = 1; static CLOSING = 2; static CLOSED = 3
  constructor(url) {
    this.url = url
    this.readyState = 0
    queueMicrotask(() => this.onerror?.({ type: "error" }))
  }
  close() {
    if (this.readyState === 3) return
    this.onerror?.({ type: "error" })
    this.readyState = 3
    this.onclose?.({ code: 1006 })
  }
  send() {}
}

/** Errors thrown out of socket event handlers: those are what restarted the service. */
async function uncaughtDuring(run) {
  const uncaught = []
  const onUncaught = e => uncaught.push(`${e.name}: ${e.message}`)
  process.on("uncaughtException", onUncaught)
  try {
    await run()
    await new Promise(r => setTimeout(r, 100))
  } finally {
    process.off("uncaughtException", onUncaught)
  }
  return uncaught
}

test("a relay that fails the handshake: close() from onerror does not recurse", async () => {
  const pool = newPool(Node22Socket)
  const uncaught = await uncaughtDuring(async () => {
    assert.deepEqual(await pool.querySync(["wss://relay.example.com"], { kinds: [1] }, { maxWait: 500 }), [])
  })
  pool.destroy()
  assert.deepEqual(uncaught, [])
})

test("closeOnce: the first close() reaches the socket, later ones do nothing", () => {
  let calls = 0
  class Counting { close(code) { calls++; this.code = code } }
  const ws = new (closeOnce(Counting))()
  ws.close(1000)
  ws.close()
  assert.deepEqual([calls, ws.code], [1, 1000])
})

test("a real relay that resets the connection mid-handshake leaves the process standing", async () => {
  const relay = net.createServer(s => s.once("data", () => s.resetAndDestroy()))
  await new Promise(r => relay.listen(0, "127.0.0.1", r))
  const pool = newPool()
  const uncaught = await uncaughtDuring(async () => {
    assert.deepEqual(await pool.querySync([`ws://127.0.0.1:${relay.address().port}`], { kinds: [1] }, { maxWait: 1500 }), [])
  })
  pool.destroy()
  relay.close()
  assert.deepEqual(uncaught, [])
})
