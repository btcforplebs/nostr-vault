// The napplet shell runtime's rules (plan P1): manifests and the hash gate (manifest.js), what an outside napplet may
// see and sign (policy.js, Logen's decision 2: vault-private data only with the user's grant), the per-domain answers
// on fake shell pieces (dispatch.js), napplet-to-napplet (bus.js), which URLs the shell fetches (fetch-policy.js), and
// the loader page's CSP being the same string everywhere it is served. The frame itself: docs/napplets/P1_RUNTIME.md.
import test from "node:test"
import assert from "node:assert/strict"
import fs from "node:fs"
import { parseManifest, checkArtifact, domainsFor, nappletKey, nappletLine, SHELL_DOMAINS } from "../src/napplet/manifest.js"
import { visibleEvents, signDecision, resendDecision, defaultGrant, grantStore, PRIVATE_KINDS } from "../src/napplet/policy.js"
import { createHandlers, cleanFilters, MAX_EVENTS, STORAGE_VALUE_MAX, MAX_SUBS } from "../src/napplet/dispatch.js"
import { createBus } from "../src/napplet/bus.js"
import { blockedUrl } from "../src/napplet/fetch-policy.js"
import { loaderCsp, LOADER_FILE } from "../src/napplet/csp.js"
import { askWords, domainWord, PRIVATE_WORDS, tagSummary } from "../src/napplet/consent-words.js"

const PUB = "a".repeat(64), H = "b".repeat(64), ME = "c".repeat(64), BAD = "d".repeat(64)
const manifest = (tags, kind = 35129) => ({ kind, pubkey: PUB, id: "e".repeat(64), tags })

test("manifest: one x tag, d tag, R/O domains, z roles, i intents", () => {
  const m = parseManifest(manifest([["d", "emoji"], ["x", H], ["R", "identity"], ["R", "storage"], ["O", "storage"], ["O", "notify"], ["z", "picker"], ["i", "emoji:pick"], ["title", "Emoji"]]))
  assert.deepEqual([m.dTag, m.hash, m.required, m.optional, m.roles, m.intents, m.title], ["emoji", H, ["identity", "storage"], ["notify"], ["picker"], ["emoji:pick"], "Emoji"])
  assert.throws(() => parseManifest(manifest([["d", "x"], ["x", H], ["x", H]])), /exactly one artifact/)
  assert.throws(() => parseManifest(manifest([["d", "x"]])), /exactly one artifact/)
  assert.throws(() => parseManifest(manifest([["x", H]])), /no d tag/)
  assert.throws(() => parseManifest(manifest([["d", "x"], ["x", H]], 1)), /not a napplet manifest/)
  assert.throws(() => parseManifest(manifest([["d", "x"], ["x", H], ["R", "Bad Domain!"]])), /malformed domain/)
})

test("manifest: the artifact must hash to x; required domains the shell lacks refuse to run", () => {
  const m = parseManifest(manifest([["d", "x"], ["x", H], ["R", "identity"], ["O", "ble"], ["O", "theme"]]))
  assert.doesNotThrow(() => checkArtifact(m, H))
  assert.throws(() => checkArtifact(m, "f".repeat(64)), /not the manifest's/)
  assert.deepEqual(domainsFor(m), ["shell", "identity", "theme"]) // ble is optional and not ours: left out
  assert.throws(() => domainsFor(parseManifest(manifest([["d", "x"], ["x", H], ["R", "dm"]]))), /can't run it: no dm/)
  assert.equal(nappletKey({ publisher: PUB, dTag: "x", hash: H }), `${PUB}:x:${H}`)
  assert.equal(nappletLine({ publisher: PUB, dTag: "x" }), `${PUB}:x`)
})

test("policy: outside napplets lose private kinds and blocked authors; first-party keeps private, never blocked", () => {
  const evs = [{ id: "1", kind: 1, pubkey: PUB }, { id: "2", kind: 4, pubkey: PUB }, { id: "3", kind: 1059, pubkey: PUB }, { id: "4", kind: 1, pubkey: BAD }]
  const blocked = new Set([BAD])
  assert.deepEqual(visibleEvents(evs, defaultGrant(), { blocked }).map(e => e.id), ["1"])
  assert.deepEqual(visibleEvents(evs, { ...defaultGrant(), privateData: true }, { blocked }).map(e => e.id), ["1", "2", "3"])
  assert.deepEqual(visibleEvents(evs, defaultGrant({ firstParty: true }), { blocked }).map(e => e.id), ["1", "2", "3"])
  assert.ok(PRIVATE_KINDS.has(4) && PRIVATE_KINDS.has(1059) && PRIVATE_KINDS.has(10000) && !PRIVATE_KINDS.has(1))
})

test("policy: what may be signed, and when the user is asked first", () => {
  const out = defaultGrant(), ours = defaultGrant({ firstParty: true })
  assert.deepEqual(signDecision(out, { kind: 1, content: "hi", tags: [] }), { ok: true, ask: true })
  assert.deepEqual(signDecision(ours, { kind: 1, content: "hi", tags: [] }), { ok: true, ask: false })
  for (const k of [0, 3, 10000, 10002]) for (const g of [out, ours]) assert.equal(signDecision(g, { kind: k, content: "", tags: [] }).ok, false) // account lists: no napplet
  for (const k of [22242, 24242, 27235]) assert.equal(signDecision(ours, { kind: k, content: "", tags: [] }).ok, false) // credentials: nobody
  assert.equal(signDecision(out, { kind: 4, content: "x", tags: [] }).ok, false)
  assert.equal(signDecision({ ...out, privateData: true }, { kind: 4, content: "x", tags: [] }).ok, true)
  assert.equal(signDecision(out, { kind: 1, content: 5, tags: [] }).ok, false)
  assert.equal(signDecision(out, { kind: 1, content: "x", tags: [["p", 1]] }).ok, false)
  assert.equal(signDecision(out, { kind: 1.5, content: "x" }).ok, false)
})

test("grants are kept per account", () => {
  const mem = new Map(), storage = { getItem: k => mem.get(k) ?? null, setItem: (k, v) => mem.set(k, v) }
  const a = grantStore(storage, "acct-a"), b = grantStore(storage, "acct-b")
  a.set("n1", { privateData: true })
  assert.deepEqual(a.get("n1"), { privateData: true })
  assert.equal(b.get("n1"), null)
  a.remove("n1")
  assert.equal(a.get("n1"), null)
})

// A fake shell: a vault with one private and one public note, a network with one note and one from a blocked author.
function fakeDeps(over = {}) {
  const vault = [{ id: "v1", kind: 1, pubkey: ME, created_at: 30 }, { id: "v4", kind: 4, pubkey: ME, created_at: 31 }]
  const net = [{ id: "n1", kind: 1, pubkey: PUB, created_at: 20 }, { id: "nb", kind: 1, pubkey: BAD, created_at: 40 }]
  const kv = new Map(), calls = { vault: 0, net: 0, published: [], asked: [], signed: [] }
  const deps = {
    pubkey: ME,
    account: () => ({ follows: [PUB], relays: { read: ["wss://r"], write: ["wss://w"] }, profileEvent: { content: '{"name":"me"}' } }),
    blocked: () => new Set([BAD]),
    verify: ev => ev?.sig === "good",
    sign: async t => { calls.signed.push(t); return { ...t, id: "s".repeat(64), pubkey: ME, sig: "good" } },
    publish: async ev => { calls.published.push(ev); return { ok: true, relays: { "wss://w": true } } },
    vaultQuery: async () => { calls.vault++; return vault },
    netQuery: async () => { calls.net++; return net },
    netSubscribe: (fs, onEvent, onEose) => { for (const e of net) onEvent(e); onEose(); return () => { calls.closedSub = true } },
    theme: () => ({ colors: { background: "#000", text: "#fff", primary: "#e67326" } }),
    storage: { get: async (s, k) => kv.get(`${s}|${k}`), set: async (s, k, v) => kv.set(`${s}|${k}`, v), remove: async (s, k) => kv.delete(`${s}|${k}`), keys: async s => [...kv.keys()].filter(x => x.startsWith(`${s}|`)).map(x => x.slice(s.length + 1)) },
    resourceSchemes: () => ["data", "https", "blossom"],
    fetchBytes: async (url, o) => { calls.fetch = { url, ...o }; if (url === "https://x/missing") throw Object.assign(new Error("nf"), { code: "not-found" }); return { blob: new Blob(["ok"]), mime: "text/plain" } },
    upload: async (blob, mime) => ({ url: "https://m/abc", sha256: H, size: blob.size, mime }),
    notify: async () => "n-1",
    ask: async q => { calls.asked.push(q.what); return over.answer ?? true },
    saveGrant: g => { calls.savedGrant = g },
    bus: createBus(),
    randomId: () => "u-1",
    ...over,
  }
  return { deps, calls, kv }
}
const ident = { publisher: PUB, dTag: "t", hash: H, title: "Test" }
const napplet = () => { const sent = []; return { dTag: "t", hash: H, sent, send: m => sent.push(m) } }
const make = (grant, over) => { const f = fakeDeps(over); return { ...f, ...createHandlers({ ident, grant, domains: SHELL_DOMAINS, deps: f.deps }) } }

test("dispatch: an outside napplet without the grant never reads the vault, and gets no private or blocked events", async () => {
  const { handlers, calls } = make(defaultGrant())
  const r = await handlers.outbox({ type: "outbox.query", id: "q", filters: [{ kinds: [1, 4] }] }, napplet())
  assert.equal(calls.vault, 0)
  assert.deepEqual(r.events.map(x => x.event.id), ["n1"])
  const m = await handlers.identity({ type: "identity.getMutes", id: "m" })
  assert.deepEqual(m.pubkeys, [])
  assert.match(m.error, /private/)
})

test("dispatch: with the grant it reads the vault first, newest first, still block-filtered", async () => {
  const { handlers, calls } = make({ ...defaultGrant(), privateData: true })
  const r = await handlers.relay({ type: "relay.query", id: "q", filters: [{ kinds: [1, 4] }] }, napplet())
  assert.equal(calls.vault, 1)
  assert.deepEqual(r.events.map(x => x.event.id), ["v4", "v1", "n1"])
  assert.deepEqual((await handlers.identity({ type: "identity.getBlocked", id: "b" })).pubkeys, [BAD])
})

test("dispatch: filters are capped and garbage is refused", async () => {
  assert.equal(cleanFilters({ limit: 99999 })[0].limit, MAX_EVENTS)
  assert.throws(() => cleanFilters([]), /invalid/)
  assert.throws(() => cleanFilters(Array(11).fill({})), /invalid/)
  const { handlers } = make(defaultGrant())
  assert.match((await handlers.outbox({ type: "outbox.query", id: "q", filters: "x" }, napplet())).error, /invalid/)
})

test("dispatch: publish asks an outside napplet's user, signs with the shell, and refuses account lists", async () => {
  const { handlers, calls } = make(defaultGrant())
  const ok = await handlers.outbox({ type: "outbox.publish", id: "p", event: { kind: 1, content: "hello", tags: [] } }, napplet())
  assert.equal(ok.ok, true)
  assert.deepEqual(calls.asked, ["publish"])
  assert.equal(calls.published.length, 1)
  const no = await handlers.outbox({ type: "outbox.publish", id: "p2", event: { kind: 3, content: "", tags: [] } }, napplet())
  assert.equal(no.ok, false)
  assert.equal(calls.signed.length, 1) // the kind 3 never reached the signer
  const said = make(defaultGrant(), { answer: false })
  const r = await said.handlers.outbox({ type: "outbox.publish", id: "p3", event: { kind: 1, content: "x", tags: [] } }, napplet())
  assert.deepEqual([r.ok, said.calls.signed.length], [false, 0])
})

test("dispatch: first-party napplets publish without a question", async () => {
  const { handlers, calls } = make(defaultGrant({ firstParty: true }))
  await handlers.outbox({ type: "outbox.publish", id: "p", event: { kind: 1, content: "x", tags: [] } }, napplet())
  assert.deepEqual(calls.asked, [])
})

test("dispatch: relay.publish sends only verified events, and an outside napplet's only after a yes", async () => {
  const { handlers, calls } = make(defaultGrant())
  assert.equal((await handlers.relay({ type: "relay.publish", id: "a", event: { kind: 1, sig: "bad" } }, napplet())).ok, false)
  const r = await handlers.relay({ type: "relay.publish", id: "b", event: { id: "x", kind: 1, content: "", tags: [], sig: "good" } }, napplet())
  assert.deepEqual([r.ok, calls.asked], [true, ["relay-publish"]])
  assert.equal((await handlers.relay({ type: "relay.publish", id: "c", event: { kind: 4, sig: "good" } }, napplet())).ok, false)
})

test("dispatch: subscriptions stream filtered events, close on request, and all close with the napplet", async () => {
  const { handlers, close, calls } = make(defaultGrant())
  const n = napplet()
  assert.equal(await handlers.relay({ type: "relay.subscribe", id: "s", subId: "a", filters: [{ kinds: [1] }] }, n), undefined)
  await new Promise(r => setTimeout(r, 0))
  assert.deepEqual(n.sent.map(m => m.type + ":" + (m.result?.event.id ?? "")), ["relay.event:n1", "relay.eose:"])
  assert.equal((await handlers.relay({ type: "relay.subscribe", id: "s2", subId: "a", filters: [{}] }, n)).type, "relay.closed") // same subId twice
  close()
  assert.equal(calls.closedSub, true)
  for (let i = 0; i < MAX_SUBS; i++) await handlers.outbox({ type: "outbox.subscribe", id: "x", subId: `s${i}`, filters: [{}] }, n)
  assert.match((await handlers.outbox({ type: "outbox.subscribe", id: "x", subId: "over", filters: [{}] }, n)).reason, /at most/)
})

test("dispatch: storage is per napplet scope, size-capped", async () => {
  const { handlers, kv } = make(defaultGrant())
  await handlers.storage({ type: "storage.set", id: "1", key: "k", value: "v" })
  await handlers.storage({ type: "storage.set", id: "2", key: "k", value: "w", scope: "shared" })
  assert.deepEqual([...kv.keys()].sort(), [`${PUB}:t:${H}|k`, `${PUB}:t|k`].sort())
  assert.equal((await handlers.storage({ type: "storage.get", id: "3", key: "k" })).value, "v")
  assert.match((await handlers.storage({ type: "storage.set", id: "4", key: "big", value: "x".repeat(STORAGE_VALUE_MAX + 1) })).error, /quota/)
  assert.match((await handlers.storage({ type: "storage.get", id: "5", key: "" })).error, /invalid key/)
})

test("dispatch: resource passes range and the private flag, maps errors to NAP codes", async () => {
  const { handlers, calls } = make(defaultGrant())
  const ok = await handlers.resource({ type: "resource.bytes", id: "1", url: "https://x/a", range: { start: 10, end: 20 } })
  assert.equal(ok.type, "resource.bytes.result")
  assert.deepEqual([calls.fetch.range, calls.fetch.private], [{ start: 10, end: 20 }, false])
  const nf = await handlers.resource({ type: "resource.bytes", id: "2", url: "https://x/missing" })
  assert.deepEqual([nf.type, nf.error], ["resource.bytes.error", "not-found"])
  const many = await handlers.resource({ type: "resource.bytesMany", id: "3", requests: [{ url: "https://x/a" }, { url: "https://x/missing" }] })
  assert.deepEqual(many.items.map(i => i.ok), [true, false])
})

test("dispatch: upload asks first for an outside napplet; a no uploads nothing", async () => {
  const yes = make(defaultGrant())
  const r = await yes.handlers.upload({ type: "upload.upload", id: "1", request: { data: new Blob(["abc"]), mimeType: "image/png" } })
  assert.deepEqual([r.result.ok, r.result.url, yes.calls.asked], [true, "https://m/abc", ["upload"]])
  const no = make(defaultGrant(), { answer: false, upload: async () => { throw new Error("must not upload") } })
  assert.equal((await no.handlers.upload({ type: "upload.upload", id: "2", request: { data: new Blob(["abc"]) } })).result.status, "cancelled")
})

test("dispatch: notify asks once, then keeps the yes", async () => {
  const grant = defaultGrant()
  const { handlers, calls } = make(grant)
  assert.equal((await handlers.notify({ type: "notify.send", id: "1", title: "t" })).notificationId, "n-1")
  await handlers.notify({ type: "notify.send", id: "2", title: "t" })
  assert.deepEqual(calls.asked, ["notify"])
  assert.equal(calls.savedGrant.notify, true)
})

test("bus: inc reaches subscribers but not the sender; intents open the handler and deliver", async () => {
  const opened = napplet()
  const bus = createBus({ handlers: [{ id: "emoji", title: "Emoji", archetype: "emoji", actions: ["pick"], conventions: [], open: async () => opened }] })
  const a = napplet(), b = napplet()
  bus.subscribe(a, "t"); bus.subscribe(b, "t")
  bus.emit(a, "t", 1)
  assert.deepEqual([a.sent.length, b.sent[0]?.payload], [0, 1])
  bus.forget(b); bus.emit(a, "t", 2)
  assert.equal(b.sent.length, 1)
  const r = await bus.invoke(a, { archetype: "emoji", action: "pick", convention: "", payload: { q: "x" } })
  assert.deepEqual([r.ok, r.handler, opened.sent[0].type, opened.sent[0].delivery.payload], [true, "emoji", "intent.deliver", { q: "x" }])
  assert.equal((await bus.invoke(a, { archetype: "emoji", action: "nope" })).ok, false)
  assert.equal(bus.available("none").available, false)
})

test("fetch policy: https to the public web only; never the user's own network or a mesh host", () => {
  for (const ok of ["https://blossom.primal.net/x.jpg", "https://8.8.8.8/a", "data:text/plain,hi"]) assert.equal(blockedUrl(ok), null, ok)
  for (const [u, code] of [["http://example.com/", "unsupported-scheme"], ["https://192.168.1.1/", "blocked-by-policy"], ["https://10.0.0.2/", "blocked-by-policy"], ["https://127.0.0.1/", "blocked-by-policy"],
    ["https://localhost/", "blocked-by-policy"], ["https://router.lan/", "blocked-by-policy"], ["https://npub1x.fips/", "blocked-by-policy"], ["https://[::1]/", "blocked-by-policy"], ["https://[fd00::1]/", "blocked-by-policy"],
    ["https://user:pw@example.com/", "blocked-by-policy"], ["https://intranet/", "blocked-by-policy"], ["not a url", "invalid-request"], ["https://100.64.0.1/", "blocked-by-policy"]]) assert.equal(blockedUrl(u), code, u)
})

test("the loader's CSP is one string: csp.js, nginx and the page served beside index.html", () => {
  const nginx = fs.readFileSync(new URL("../../website/nginx.conf", import.meta.url), "utf8")
  const line = nginx.split("\n").find(l => l.includes("~^/vault/napplet-frame"))
  assert.ok(line.includes(`"${loaderCsp()}"`), "nginx's loader CSP differs from src/napplet/csp.js")
  // The map takes its first matching regex: the loader's entry must come before /vault/'s.
  assert.ok(nginx.indexOf("napplet-frame\\.html") < nginx.indexOf("~^/(relay|vault)/  \"default-src 'self'"))
  assert.match(loaderCsp(), /connect-src 'none'/)
  assert.match(loaderCsp(), /frame-ancestors 'self'/)
  assert.match(loaderCsp(), /sandbox allow-scripts$/)
  const page = fs.readFileSync(new URL(`../public/${LOADER_FILE}`, import.meta.url), "utf8")
  assert.match(page, /e\.source !== parent/)
  assert.match(page, /nv-loader\.ready/)
})

test("consent words cover every domain the shell offers", () => {
  for (const d of SHELL_DOMAINS.filter(d => d !== "shell")) assert.notEqual(domainWord(d), d, d)
  assert.match(askWords("publish", { title: "Emoji" }, { kind: 1, content: "hi" }).title, /Emoji wants to post a note as you/)
})

// Tron's review of PR 2057: vanish, deletions aimed at account lists, replayed lists, the sheet hiding tags.
const MINE = "1".repeat(64), MYLIST = "2".repeat(64), THEIRS = "3".repeat(64), GONE = "4".repeat(64)
const withEvents = evs => ({ vaultQuery: async fs => evs.filter(e => fs[0].ids?.includes(e.id)), netQuery: async () => [] })
const own = [{ id: MINE, kind: 1, pubkey: ME, created_at: 1 }, { id: MYLIST, kind: 3, pubkey: ME, created_at: 2 }, { id: THEIRS, kind: 1, pubkey: PUB, created_at: 3 }]
const del = tags => ({ type: "outbox.publish", id: "d", event: { kind: 5, content: "", tags } })

test("policy: no napplet gets a vanish request or a deletion of a protected kind signed", () => {
  for (const g of [defaultGrant(), defaultGrant({ firstParty: true })]) {
    assert.equal(signDecision(g, { kind: 62, content: "Thanks!", tags: [["relay", "ALL_RELAYS"]] }).ok, false)
    assert.equal(signDecision(g, { kind: 5, content: "", tags: [["a", `3:${ME}:`]] }).ok, false)
    assert.equal(signDecision(g, { kind: 5, content: "", tags: [["a", `10002:${ME}:`]] }).ok, false)
    assert.equal(signDecision(g, { kind: 5, content: "", tags: [["e", MINE], ["k", "3"]] }).ok, false)
    assert.equal(signDecision(g, { kind: 5, content: "", tags: [["a", `x:${ME}:`]] }).ok, false) // unreadable kind
    assert.equal(signDecision(g, { kind: 5, content: "", tags: [] }).ok, false) // deletes nothing named
  }
  assert.deepEqual(signDecision(defaultGrant(), { kind: 5, content: "", tags: [["e", MINE], ["k", "1"]] }), { ok: true, ask: true })
})

test("dispatch: a deletion's e ids are looked up: only the user's own, found, unprotected events", async () => {
  const run = async tags => { const m = make(defaultGrant(), withEvents(own)); const r = await m.handlers.outbox(del(tags), napplet()); return [r.ok, m.calls.signed.length, m.calls.asked] }
  assert.deepEqual(await run([["e", MYLIST], ["k", "1"]]), [false, 0, []]) // says kind 1, is the follow list
  assert.deepEqual(await run([["e", GONE]]), [false, 0, []]) // can't be checked
  assert.deepEqual(await run([["e", THEIRS]]), [false, 0, []]) // not the user's
  assert.deepEqual(await run([["e", "nothex"]]), [false, 0, []])
  assert.deepEqual(await run([["e", MINE]]), [true, 1, ["publish"]])
})

test("dispatch: relay.publish won't replay a signed list, vanish request or deletion", async () => {
  const { handlers, calls } = make(defaultGrant({ firstParty: true }))
  for (const kind of [0, 3, 10002, 62, 5, 22242]) {
    const r = await handlers.relay({ type: "relay.publish", id: "r", event: { id: "x", kind, pubkey: ME, content: "", tags: [], sig: "good" } }, napplet())
    assert.equal(r.ok, false, `kind ${kind}`)
  }
  assert.equal(calls.published.length, 0)
  assert.deepEqual(resendDecision({ kind: 1 }), { ok: true })
})

test("ask sheet: deletions say so; unnamed kinds show their tags; the grant says data can leave", () => {
  const d = askWords("publish", { title: "Cool app" }, { kind: 5, content: "", tags: [["e", MINE], ["a", `30023:${ME}:x`]] })
  assert.equal(d.title, "Cool app wants to delete 2 of your posts")
  assert.equal(d.yes, "Delete")
  const odd = askWords("publish", { title: "Cool app" }, { kind: 9999, content: "Thanks!", tags: [["p", PUB], ["p", ME], ["e", MINE]] })
  assert.match(odd.body, /Thanks!/)
  assert.match(odd.body, /Tags: 2 p \(people\), 1 e \(events\)/)
  assert.doesNotMatch(askWords("publish", {}, { kind: 1, content: "hi", tags: [["p", PUB]] }).body, /Tags/)
  assert.equal(tagSummary([]), "No tags.")
  assert.match(PRIVATE_WORDS.help, /send what it sees to whoever made it/)
})

test("storage: two picked files with the same name don't share storage", async () => {
  // runtime.js localManifest: publisher "local", dTag = the file's name (runtime.js imports the shim, not node-safe)
  assert.notEqual(nappletLine({ publisher: "local", dTag: "napplet.html", hash: H }), nappletLine({ publisher: "local", dTag: "napplet.html", hash: "f".repeat(64) }))
  assert.equal(nappletLine({ publisher: PUB, dTag: "x", hash: H }), nappletLine({ publisher: PUB, dTag: "x", hash: "f".repeat(64) })) // published: across versions
})
