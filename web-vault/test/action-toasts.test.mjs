// Feedback pills (ActionToastBanner, LikeFeedback): one shared toast, and the like's "Liked" / "Reacted 🔥" /
// "Like failed: …" once it has landed or failed. Throwaway keys, relays stubbed: nothing is published.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"
import { finalizeEvent, generateSecretKey, getPublicKey } from "nostr-tools/pure"
import { pool } from "../src/net/pool.js"

registerHooks({ load(url, context, next) {
  if (!url.endsWith(".jsx")) return next(url, context)
  const { code } = transformSync(fileURLToPath(url), readFileSync(fileURLToPath(url), "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
  return { format: "module", source: code, shortCircuit: true }
} })
const { showToast, hideToast, currentToasts } = await import("../src/components/Toast.jsx")
const { likeFeedback, likeWithFeedback } = await import("../src/components/ReactionButton.jsx")

const me = generateSecretKey(), author = generateSecretKey()
let n0 = 0
const note = () => finalizeEvent({ kind: 1, created_at: Math.floor(Date.now() / 1000) - 60, tags: [], content: `note ${++n0}` }, author)
const ctxFor = () => {
  const kept = []
  return {
    session: { pubkey: getPublicKey(me) },
    signer: { signEvent: async t => finalizeEvent(t, me) },
    account: { relays: { read: ["wss://relay.example.com"], write: ["wss://relay.example.com"] } },
    vault: { outbox: { event: async ev => { kept.push(ev); return { ok: true, message: "" } }, query: async () => [] }, feed: { query: async () => [] } },
  }
}
const relaysSay = (t, answer) => {
  t.mock.method(pool, "publish", urls => urls.map(answer))
  globalThis.location = { hostname: "vault.example.com", hash: "" }
  t.after(() => { delete globalThis.location })
}
const clear = () => { for (const t of currentToasts()) hideToast(t.key) }

test("one pill per key: showing a key again replaces it, another key stacks under it", t => {
  t.mock.timers.enable({ apis: ["setTimeout"] })
  clear()
  showToast({ key: "like", message: "Liked" })
  showToast({ key: "like", message: "Reacted 🔥" })
  showToast({ key: "zap", message: "Zapping Alice", icon: "bolt", seconds: 0 })
  assert.deepEqual(currentToasts().map(x => [x.key, x.message]), [["like", "Reacted 🔥"], ["zap", "Zapping Alice"]])
  t.mock.timers.tick(2500)
  assert.deepEqual(currentToasts().map(x => x.message), ["Zapping Alice"]) // 0 seconds: stays until replaced
  showToast({ key: "zap", message: "Zap failed", tone: "error" })
  t.mock.timers.tick(3999)
  assert.equal(currentToasts().length, 1) // an error stays 4 s
  t.mock.timers.tick(1)
  assert.equal(currentToasts().length, 0)
})

test("a pill's own timer never takes away the newer pill that replaced it", t => {
  t.mock.timers.enable({ apis: ["setTimeout"] })
  clear()
  showToast({ key: "like", message: "Liked" })
  t.mock.timers.tick(2000)
  showToast({ key: "like", message: "Reacted 😂" })
  t.mock.timers.tick(600)
  assert.deepEqual(currentToasts().map(x => x.message), ["Reacted 😂"])
})

test("the like's words, as LikeFeedback says them", () => {
  assert.deepEqual(likeFeedback("sent", "❤️"), { message: "Liked", tone: "accent", icon: "heart" })
  assert.equal(likeFeedback("sent", "+").message, "Liked")
  assert.equal(likeFeedback("sent", "🔥").message, "Reacted 🔥")
  assert.equal(likeFeedback({ error: "No relay took it (0 of 3)" }).message, "Like failed: no relay took it")
  assert.equal(likeFeedback({ error: "The signer timed out" }).message, "Like failed: your signer didn't answer")
  assert.equal(likeFeedback({ error: "x" }).tone, "error")
  assert.equal(likeFeedback({ error: "down", unlike: true }), null) // an Unlike that failed says so on the heart
  assert.equal(likeFeedback(undefined), null) // an Unlike that went out leaves no like to report
})

test("a like that lands says Liked; one with an emoji says Reacted", async t => {
  relaysSay(t, () => Promise.resolve(""))
  clear()
  await likeWithFeedback(ctxFor(), note())
  assert.deepEqual(currentToasts().map(x => [x.key, x.message, x.tone]), [["like", "Liked", "accent"]])
  await likeWithFeedback(ctxFor(), note(), "🔥")
  assert.deepEqual(currentToasts().map(x => x.message), ["Reacted 🔥"])
  clear()
})

test("a like no relay took says Like failed, in red", async t => {
  relaysSay(t, () => Promise.reject(new Error("down")))
  clear()
  await likeWithFeedback(ctxFor(), note())
  assert.deepEqual(currentToasts().map(x => [x.message, x.tone]), [["Like failed: no relay took it", "error"]])
  clear()
})
