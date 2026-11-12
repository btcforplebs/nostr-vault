// Box › Public on the web (src/box/public-on-web.js): which address is listed, and what a tap publishes. Nothing is
// sent anywhere: publish is a stand-in that records what it was given.
import test from "node:test"
import assert from "node:assert/strict"
import { boxRelay, boxInbox, listed, withRelay, setListed } from "../src/box/public-on-web.js"

test("the box's web address becomes a public wss relay, or nothing", () => {
  assert.equal(boxRelay("vault.example.com"), "wss://vault.example.com")
  assert.equal(boxRelay("https://Vault.Example.com/"), "wss://vault.example.com")
  for (const none of ["", null, undefined, "localhost:3355", "192.168.1.20", "box.local", "ftp://x.example.com"])
    assert.equal(boxRelay(none), null, String(none))
  assert.equal(boxInbox("wss://vault.example.com"), "wss://vault.example.com/inbox")
})

test("listed matches any spelling; withRelay adds first and removes every spelling", () => {
  const tags = [["r", "wss://relay.damus.io"], ["r", "wss://Vault.example.com/", "write"]]
  assert.ok(listed(tags, "r", "wss://vault.example.com"))
  assert.ok(!listed(tags, "relay", "wss://vault.example.com"))
  assert.deepEqual(withRelay(tags, "r", "wss://vault.example.com", false), [["r", "wss://relay.damus.io"]])
  assert.deepEqual(withRelay([["r", "wss://relay.damus.io"]], "r", "wss://vault.example.com", true),
    [["r", "wss://vault.example.com"], ["r", "wss://relay.damus.io"]])
})

const recorder = () => {
  const calls = []
  return { calls, publish: async (_ctx, kind, tags, opts) => { calls.push({ kind, tags, previous: opts.previous }) } }
}
const relay = "wss://vault.example.com"
const state = (relayTags, inboxTags) => ({
  relays: { event: relayTags && { id: "a", tags: relayTags } },
  inbox: { event: inboxTags && { id: "b", tags: inboxTags } },
})

test("on: 10002 then 10050, each built on the copy that was read", async () => {
  const r = recorder()
  const s = state([["r", "wss://relay.damus.io"]], [["relay", "wss://inbox.nostr.wine"]])
  assert.deepEqual(await setListed({}, relay, true, s, r.publish), [10002, 10050])
  assert.deepEqual(r.calls.map(c => [c.kind, c.tags, c.previous.id]), [
    [10002, [["r", relay], ["r", "wss://relay.damus.io"]], "a"],
    [10050, [["relay", relay + "/inbox"], ["relay", "wss://inbox.nostr.wine"]], "b"],
  ])
})

test("off: both lose it, the rest stays", async () => {
  const r = recorder()
  const s = state([["r", relay], ["r", "wss://relay.damus.io"]], [["relay", relay + "/inbox"], ["relay", "wss://inbox.nostr.wine"]])
  await setListed({}, relay, false, s, r.publish)
  assert.deepEqual(r.calls.map(c => c.tags), [[["r", "wss://relay.damus.io"]], [["relay", "wss://inbox.nostr.wine"]]])
})

test("nothing to change publishes nothing: never an empty list signed for nothing", async () => {
  const r = recorder()
  assert.deepEqual(await setListed({}, relay, false, state(null, null), r.publish), [])
  assert.deepEqual(await setListed({}, relay, true, state([["r", relay]], [["relay", relay + "/inbox"]]), r.publish), [])
  assert.equal(r.calls.length, 0)
})

test("a refused 10002 stops before the 10050", async () => {
  const calls = []
  const publish = async (_c, kind) => { calls.push(kind); throw new Error("Not saved: your relays didn't answer") }
  await assert.rejects(setListed({}, relay, true, state([], []), publish), /Not saved/)
  assert.deepEqual(calls, [10002])
})

test("off refuses, signing nothing, when the box is the only relay in either list (Tron #1991)", async () => {
  for (const [relays, inbox, what] of [
    [[["r", relay]], [["relay", relay + "/inbox"], ["relay", "wss://inbox.nostr.wine"]], /relay list/],
    [[["r", relay], ["r", "wss://relay.damus.io"]], [["relay", relay + "/inbox"]], /DM inbox/],
  ]) {
    const r = recorder()
    await assert.rejects(setListed({}, relay, false, state(relays, inbox), r.publish), what)
    assert.equal(r.calls.length, 0, "neither list signed, so none is left half-moved")
  }
})

test("publishList never signs an empty relay list or DM inbox", async () => {
  const { publishList, ListNotSaved } = await import("../src/net/list-edit.js")
  let signed = 0
  const ctx = { signer: { signEvent: async () => { signed++ } } }
  for (const [kind, tags] of [[10002, []], [10002, [["alt", "x"]]], [10050, []], [10050, [["relay", ""]]]])
    await assert.rejects(publishList(ctx, kind, tags, { latest: async () => ({ checked: true, event: null }) }),
      e => e instanceof ListNotSaved && /no relay/.test(e.message), `${kind} ${JSON.stringify(tags)}`)
  assert.equal(signed, 0)
})
