// Logen's three shell rules for napplets (nv-3.0, 2026-11-14; plan RESEARCH/NV_WEB_NAPPLET_PLAN.md §8):
// 1. An outside napplet never gets the vault's private data, whatever a grant says (Logen 15:20Z). Only our own,
//    first-party napplets do.
// 2. Napplets reach relays only through Haven and see only what passed the web of trust (Logen 13:41Z): every read
//    is answered from Haven first; what the shell fetches from the network passes the WoT gate and goes into Haven
//    before a napplet sees it. Our own napplets too.
// 3. No napplet gets the emoji list (10030) or emoji sets (30030) signed (Tara 14:47Z).
import test from "node:test"
import assert from "node:assert/strict"
import fs from "node:fs"
import { visibleEvents, signDecision, resendDecision, defaultGrant, seesPrivate, outsideGrant, protectedKind } from "../src/napplet/policy.js"
import { wotGate } from "../src/napplet/wot-gate.js"
import { createHandlers, OUTSIDE_STORE_PER_MIN } from "../src/napplet/dispatch.js"
import { dmHandler } from "../src/napplet/dm-dispatch.js"
import { blossomHandler } from "../src/napplet/blossom-dispatch.js"
import { SHELL_DOMAINS } from "../src/napplet/manifest.js"
import { createBus } from "../src/napplet/bus.js"

const H = c => c.repeat(64)
const ME = H("a"), FRIEND = H("b"), FOF = H("c"), STRANGER = H("d"), BAD = H("e"), PUB = H("f")
// What an old build's Access sheet could have saved for an outside napplet: the private-data switch on.
const oldGrant = (domains = SHELL_DOMAINS) => ({ ...defaultGrant({ domains }), privateData: true })

// ---- 1. private data is first-party only ----

test("rule 1: a saved private-data grant gives an outside napplet nothing private", () => {
  const evs = [{ id: "1", kind: 1, pubkey: FRIEND }, { id: "2", kind: 4, pubkey: FRIEND }, { id: "3", kind: 1059, pubkey: FRIEND }, { id: "4", kind: 10000, pubkey: ME }]
  assert.equal(seesPrivate(oldGrant()), false)
  assert.deepEqual(visibleEvents(evs, oldGrant()).map(e => e.id), ["1"])
  assert.deepEqual(visibleEvents(evs, defaultGrant({ firstParty: true })).map(e => e.id), ["1", "2", "3", "4"])
  for (const k of [4, 14, 1059, 30078, 7375]) assert.equal(signDecision(oldGrant(), { kind: k, content: "x", tags: [] }).ok, false)
})

test("rule 1: an outside napplet's stored grant can't claim first-party or private data", () => {
  const g = outsideGrant({ firstParty: true, privateData: true, domains: ["shell", "relay"], notify: true, publish: "allow" })
  assert.equal(g.firstParty, false)
  assert.equal(seesPrivate(g), false)
  assert.equal("privateData" in g, false)
  assert.deepEqual(g.domains, ["shell", "relay"])
  assert.equal(g.publish, "ask")
  assert.equal(g.notify, true) // a yes to notifications is kept
  assert.equal(outsideGrant(null).firstParty, false)
})

test("rule 1: an outside napplet with an old grant reads only Haven's public cache, never mutes or blocks", async () => {
  const { handlers, calls } = make(oldGrant())
  await handlers.relay({ type: "relay.query", id: "q", filters: [{ kinds: [1] }] }, napplet())
  assert.deepEqual(calls.routes, ["public"])
  const m = await handlers.identity({ type: "identity.getMutes", id: "m" })
  assert.deepEqual(m.pubkeys, [])
  const ours = make(defaultGrant({ firstParty: true }))
  await ours.handlers.relay({ type: "relay.query", id: "q", filters: [{ kinds: [1] }] }, napplet())
  assert.deepEqual(ours.calls.routes, ["all"])
})

test("rule 1: an outside napplet with an old grant gets no DMs and can't send one", async () => {
  const sent = []
  const h = dmHandler({
    grant: oldGrant(["dm"]), who: { title: "X" }, push: () => {},
    deps: { me: ME, messages: () => new Map([["m1", { id: "m1", from: FRIEND, peer: FRIEND, at: 1, content: "hi" }]]), blocked: () => new Set(), trusted: () => new Set([FRIEND]), unread: () => new Map(), profile: () => null, onChange: () => () => {}, send: async (p, t) => { sent.push(t) }, markRead: () => {}, ask: async () => true, randomId: () => "r" },
  })
  for (const t of ["dm.conversations", "dm.messages", "dm.send", "dm.subscribe"]) assert.match((await h.handle({ type: t, id: "1", conversationId: FRIEND, recipients: [FRIEND], content: "x" })).error, /private/)
  assert.equal(sent.length, 0)
})

test("rule 1: an outside napplet with an old grant sees none of your media servers or files", async () => {
  const h = blossomHandler({ grant: oldGrant(["blossom"]), who: { title: "X" }, deps: { pubkey: ME, servers: async () => ["https://m.example"], list: async () => ({ blobs: [{ sha256: H("1") }] }), ask: async () => true, now: () => 1 } })
  assert.match((await h({ type: "blossom.servers", id: "1", request: {} })).error, /private/)
  assert.match((await h({ type: "blossom.list", id: "1", request: { server: "https://m.example", pubkey: ME } })).error, /private/)
})

test("rule 1: the Access and consent sheets no longer offer private data", () => {
  // The sheets live in GrantSheet.jsx, shared by the Apps pane and the side columns' app cards.
  for (const f of ["NappletShell.jsx", "GrantSheet.jsx", "../desktop/space/AppCard.jsx"]) {
    const src = fs.readFileSync(new URL(`../src/napplet/${f}`, import.meta.url), "utf8")
    assert.doesNotMatch(src, /privateData|PRIVATE_WORDS/, f)
  }
})

// ---- 2. reads only through Haven, only inside the web of trust ----

test("rule 2: the WoT gate passes you and your web; a stranger only for an emoji set your own list names", () => {
  const pass = wotGate({ me: ME, trust: new Set([ME, FRIEND, FOF]), named: new Set([`30030:${STRANGER}:cats`]) })
  assert.equal(pass({ kind: 1, pubkey: ME }), true)
  assert.equal(pass({ kind: 1, pubkey: FOF }), true)
  assert.equal(pass({ kind: 1, pubkey: STRANGER }), false)
  assert.equal(pass({ kind: 30030, pubkey: STRANGER, tags: [["d", "cats"]] }), true)
  assert.equal(pass({ kind: 30030, pubkey: STRANGER, tags: [["d", "dogs"]] }), false)
  assert.equal(pass({ kind: 1, pubkey: STRANGER, tags: [["d", "cats"]] }), false)
  // No web yet (no follows): only your own events, fails closed for everyone else.
  const none = wotGate({ me: ME, trust: null })
  assert.equal(none({ kind: 1, pubkey: ME }), true)
  assert.equal(none({ kind: 1, pubkey: FRIEND }), false)
  assert.equal(none(null), false)
})

for (const [who, grant] of [["outside", defaultGrant()], ["first-party", defaultGrant({ firstParty: true })]]) {
  test(`rule 2 (${who}): a query asks Haven first, network events outside the web never reach the napplet, the rest go into Haven first`, async () => {
    const { handlers, calls } = make(grant)
    const r = await handlers.relay({ type: "relay.query", id: "q", filters: [{ kinds: [1] }] }, napplet())
    const ids = r.events.map(x => x.event.id)
    assert.deepEqual(ids, ["hv", "nf", "nfof"]) // newest first; stranger and blocked out
    assert.deepEqual(calls.order, ["haven", "net", "store"])
    assert.deepEqual(calls.stored.map(e => e.id), ["nf", "nfof"])
    assert.ok(!ids.includes("ns") && !ids.includes("nb"))
  })

  test(`rule 2 (${who}): a subscription gets only web-of-trust events, each put into Haven before it is passed on`, async () => {
    const { handlers, calls } = make(grant)
    const n = napplet(m => m.type === "relay.event" && calls.order.push(`pass:${m.result.event.id}`))
    await handlers.relay({ type: "relay.subscribe", subId: "s", filters: [{ kinds: [1] }] }, n)
    await new Promise(r => setTimeout(r, 10))
    const got = n.sent.filter(m => m.type === "relay.event").map(m => m.result.event.id)
    assert.deepEqual(got.sort(), ["hv", "nf", "nfof"])
    for (const id of ["nf", "nfof"]) assert.ok(calls.order.indexOf(`store:${id}`) < calls.order.indexOf(`pass:${id}`), `${id} stored before passed`)
  })
}

test("rule 2: getEvent of a stranger's note is not found", async () => {
  const { handlers } = make(defaultGrant({ firstParty: true }))
  const r = await handlers.outbox({ type: "outbox.getEvent", id: "g", eventId: H("9") }, napplet())
  assert.equal(r.error, "not-found")
})

// ---- 3. emoji list and sets are never signed for a napplet ----

test("rule 3: no napplet, ours included, gets 10030 or 30030 signed, deleted or re-sent", () => {
  for (const g of [defaultGrant(), defaultGrant({ firstParty: true })]) for (const kind of [10030, 30030]) {
    assert.equal(signDecision(g, { kind, content: "", tags: [] }).ok, false, `kind ${kind}`)
    assert.equal(signDecision(g, { kind: 5, content: "", tags: [["a", `${kind}:${ME}:x`]] }).ok, false)
    assert.equal(signDecision(g, { kind: 5, content: "", tags: [["e", H("1")], ["k", String(kind)]] }).ok, false)
  }
  assert.equal(protectedKind(10030) && protectedKind(30030), true)
  assert.equal(resendDecision({ kind: 30030 }).ok, false)
  assert.equal(resendDecision({ kind: 10030 }).ok, false)
})

// A fake shell. Haven holds one of your notes; the network has a friend's, a friend-of-friend's, a stranger's and a
// blocked one. The web: you, FRIEND, FOF.
function make(grant, { more = [], now } = {}) {
  const haven = [{ id: "hv", kind: 1, pubkey: ME, created_at: 50 }, { id: "hs", kind: 1, pubkey: STRANGER, created_at: 51 }]
  const net = [
    { id: "nf", kind: 1, pubkey: FRIEND, created_at: 40 }, { id: "nfof", kind: 1, pubkey: FOF, created_at: 30 },
    { id: "ns", kind: 1, pubkey: STRANGER, created_at: 45 }, { id: "nb", kind: 1, pubkey: BAD, created_at: 46 },
    { id: H("9"), kind: 1, pubkey: STRANGER, created_at: 1 },
    ...more,
  ]
  const calls = { routes: [], order: [], stored: [] }
  const deps = {
    pubkey: ME,
    account: () => ({ follows: [FRIEND], relays: { read: ["wss://r"], write: ["wss://w"] } }),
    blocked: () => new Set([BAD]),
    wotGate: async () => wotGate({ me: ME, trust: new Set([ME, FRIEND, FOF, BAD]) }),
    vaultQuery: async (fs, { routes = "all" } = {}) => {
      calls.routes.push(routes); calls.order.push("haven")
      return haven.filter(e => !fs[0].ids || fs[0].ids.includes(e.id))
    },
    netQuery: async fs => { calls.order.push("net"); return net.filter(e => !fs[0].ids || fs[0].ids.includes(e.id)) },
    netSubscribe: (fs, onEvent, onEose) => { for (const e of net) onEvent(e); onEose(); return () => {} },
    havenStore: async evs => { calls.order.push(evs.length === 1 && calls.order.includes("sub") ? `store:${evs[0].id}` : "store"); calls.stored.push(...evs); return evs },
    theme: () => ({}), storage: {}, resourceSchemes: () => [], fetchBytes: async () => ({}), upload: async () => ({}), notify: async () => "n",
    ask: async () => true, saveGrant: () => {}, bus: createBus(), randomId: () => "u",
    ...(now ? { now } : {}),
  }
  const origSub = deps.netSubscribe
  deps.netSubscribe = (fs, onEvent, onEose) => { calls.order.push("sub"); return origSub(fs, ev => onEvent(ev), onEose) }
  const h = createHandlers({ ident: { publisher: PUB, dTag: "t", hash: H("0"), title: "T" }, grant, domains: SHELL_DOMAINS, deps })
  return { ...h, calls }
}
function napplet(onSend = () => {}) {
  const sent = []
  return { dTag: "t", hash: H("0"), sent, send: m => { sent.push(m); onSend(m) } }
}

test("an outside napplet writes at most OUTSIDE_STORE_PER_MIN network events into Haven a minute; past it they're handed over, not kept", async () => {
  const more = Array.from({ length: 350 }, (_, i) => ({ id: `f${i}`, kind: 1, pubkey: FRIEND, created_at: 100 + i }))
  let t = 0
  const outside = make(defaultGrant({ domains: SHELL_DOMAINS }), { more, now: () => t })
  const q = async h => (await h.handlers.relay({ type: "relay.query", id: "q", filters: [{ kinds: [1], limit: 500 }] }, napplet()))
  await q(outside)
  assert.equal(outside.calls.stored.length, OUTSIDE_STORE_PER_MIN)
  const n = napplet()
  await outside.handlers.relay({ type: "relay.subscribe", subId: "s", filters: [{ kinds: [1] }] }, n)
  await new Promise(r => setTimeout(r, 20))
  assert.equal(outside.calls.stored.length, OUTSIDE_STORE_PER_MIN) // the minute's budget is spent
  assert.ok(n.sent.filter(m => m.type === "relay.event").length >= 350) // still handed over
  t = 60_000
  await q(outside)
  assert.equal(outside.calls.stored.length, 2 * OUTSIDE_STORE_PER_MIN) // a new minute, a new budget
  const ours = make(defaultGrant({ firstParty: true, domains: SHELL_DOMAINS }), { more })
  await q(ours)
  assert.ok(ours.calls.stored.length > OUTSIDE_STORE_PER_MIN) // our own napplets aren't capped
})

test("step 12 review: no napplet gets a pin, bookmark, interest or set list signed, or deleted", () => {
  for (const kind of [10001, 10003, 10015, 30000, 30003]) {
    const tags = kind >= 30000 ? [["d", "x"]] : []
    for (const grant of [{ firstParty: true }, { publish: "allow" }, null]) assert.equal(signDecision(grant, { kind, content: "", tags }).ok, false, `kind ${kind}`)
    assert.equal(protectedKind(kind), true)
    assert.equal(signDecision({ firstParty: true }, { kind: 5, content: "", tags: [["a", `${kind}:${"a".repeat(64)}:`]] }).ok, false, `delete ${kind}`)
  }
})

test("step 12 review: a blossom: link's own ?xs= servers go through the fetch policy", () => {
  const src = fs.readFileSync(new URL("../src/napplet/shell-deps.js", import.meta.url), "utf8")
  assert.match(src, /candidateServers\(b, servers\)\.filter\(s => !blockedUrl\(s\)\)/)
})
