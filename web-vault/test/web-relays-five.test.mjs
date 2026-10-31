// Web relays match the apps (Logen 2026-10-31): the web reads from the same five, a new account publishes only the
// list its relay step showed, and nothing but Settings › Relays' Save (and that step) ever sends a kind 10002.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync, readdirSync, statSync } from "node:fs"
import { join } from "node:path"
import { DEFAULT_RELAYS } from "../src/net/pool.js"
import { NEW_ACCOUNT_RELAYS, newAccountTemplates, publishNewAccount, starterList } from "../src/net/new-account.js"

const FIVE = ["wss://relay.primal.net", "wss://relay.damus.io", "wss://relay.snort.social", "wss://relay.btcforplebs.com", "wss://nostr-pub.wellorder.net"]

test("the web reads from the apps' five, and a new account starts with them", () => {
  assert.deepEqual(DEFAULT_RELAYS, FIVE)
  assert.deepEqual(NEW_ACCOUNT_RELAYS, FIVE)
})

test("a new account publishes the list its relay step showed, and nothing else", async () => {
  const mine = ["wss://relay.snort.social", "wss://my.relay.example/"]
  const t = newAccountTemplates({ name: "Ada", picture: null, follows: [], relays: mine, at: 1 })
  const tagged = kind => t.find(e => e.kind === kind).tags.map(x => x[1])
  assert.deepEqual(tagged(10002), ["wss://relay.snort.social", "wss://my.relay.example"])
  assert.deepEqual(tagged(10050), ["wss://relay.snort.social", "wss://my.relay.example"], "no defaults added to the DM list")
  const sent = new Set()
  await publishNewAccount(t.map(e => ({ ...e, id: String(e.kind) })), { relays: mine, publish: urls => { urls.forEach(u => sent.add(u)); return urls.map(() => Promise.resolve("ok")) } })
  assert.deepEqual([...sent], ["wss://relay.snort.social", "wss://my.relay.example"], "no broadcast relays added unseen")
})

test("the starter list keeps wss relays others can reach, once each", () => {
  assert.deepEqual(starterList([" wss://a.example/ ", "wss://a.example", "ws://b.example", "wss://localhost:3355", "https://c.example", "nope"]), ["wss://a.example"])
  assert.deepEqual(newAccountTemplates({ name: "", picture: null, follows: [], relays: [] }), [], "an empty list publishes no relay list")
})

// Every source file that builds or publishes a kind 10002. Only the new account's relay step (net/new-account.js) and
// Save on Settings › Relays (screens/RelaysPage.jsx, through net/list-edit.js publishList) may.
const files = dir => readdirSync(dir).flatMap(f => { const p = join(dir, f); return statSync(p).isDirectory() ? (f === "vendor" ? [] : files(p)) : /\.(js|jsx|mjs)$/.test(f) ? [p] : [] })
const writes10002 = src => /kind:\s*10002\b/.test(src) || /publishList\([^)]*\b10002\b/.test(src)

test("only the relay step and Save on Relays send a kind 10002", () => {
  const root = new URL("../src", import.meta.url).pathname
  const hits = files(root).filter(p => writes10002(readFileSync(p, "utf8"))).map(p => p.slice(root.length + 1)).sort()
  assert.deepEqual(hits, ["net/new-account.js", "screens/RelaysPage.jsx"])
  // The scan can see a new sender: both shapes are caught.
  assert.ok(writes10002(`pool.publish(r, sign({ kind: 10002, tags }))`))
  assert.ok(writes10002(`await publishList(ctx, 10002, tags)`))
  assert.ok(!writes10002(`query(r, { kinds: [0, 3, 10002] })`))
})
