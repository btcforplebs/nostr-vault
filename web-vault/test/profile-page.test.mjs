// The public profile page (thread-page/profile-page.js): the /p/ address, the HTML and preview card it draws, the relay
// read behind it, and its CSP, with signed events from throwaway keys and a fake relay query.
import test from "node:test"
import assert from "node:assert/strict"
import { finalizeEvent, generateSecretKey, getPublicKey } from "nostr-tools/pure"
import { neventEncode, nprofileEncode, npubEncode } from "nostr-tools/nip19"
import { readFileSync } from "node:fs"
import { appProfileLink, parseProfileTarget, profileFields, profileUrl, renderProfile, renderProfileMissing } from "../thread-page/profile-page.js"
import { loadProfile } from "../thread-page/fetch.js"

const alice = generateSecretKey(), mallory = generateSecretKey()
const A = getPublicKey(alice), M = getPublicKey(mallory)
const npub = npubEncode(A)
let clock = 1_760_000_000
const kind0 = (sk, fields, at = clock++) => finalizeEvent({ kind: 0, content: JSON.stringify(fields), tags: [], created_at: at }, sk)

test("the address: npub and nprofile, with or without nostr:; anything else is not a profile", () => {
  assert.deepEqual(parseProfileTarget(npub), { pubkey: A, npub, relays: [] })
  assert.equal(parseProfileTarget(`nostr:${npub}`).pubkey, A)
  const np = parseProfileTarget(nprofileEncode({ pubkey: A, relays: ["wss://relay.example.com"] }))
  assert.deepEqual([np.pubkey, np.npub, np.relays], [A, npub, ["wss://relay.example.com"]])
  assert.equal(parseProfileTarget(A), null, "a bare hex key is not what the apps share")
  assert.equal(parseProfileTarget(neventEncode({ id: A })), null)
  assert.equal(parseProfileTarget("nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5"), null)
  assert.equal(parseProfileTarget("<script>"), null)
})

test("the apps' address and the app link", () => {
  assert.equal(profileUrl(npub), `https://nostrvault.app/p/${npub}`)
  assert.equal(appProfileLink(npub), `nostrvault://p/${npub}`)
})

test("a profile's fields: https pictures only, long bios cut", () => {
  const f = profileFields(kind0(alice, { name: "alice", display_name: "Alice", picture: "http://x.example/a.jpg", banner: "https://x.example/b.jpg", about: "x".repeat(900), nip05: "alice@example.com" }))
  assert.equal(f.name, "Alice")
  assert.equal(f.picture, null)
  assert.equal(f.banner, "https://x.example/b.jpg")
  assert.equal(f.about.length, 600)
  assert.ok(f.about.endsWith("…"))
  assert.deepEqual(profileFields({ content: "not json" }), { name: null, picture: null, banner: null, about: null, nip05: null })
})

test("the page: card, name, escaped bio, the three ways in, no script", () => {
  const html = renderProfile({ target: parseProfileTarget(npub), profile: kind0(alice, { name: "Alice <b>", about: "hi <script>alert(1)</script>", picture: "https://x.example/a.jpg" }) })
  assert.match(html, /<meta property="og:title" content="Alice &lt;b&gt; on Nostr">/)
  assert.match(html, /<meta property="og:image" content="https:\/\/x.example\/a.jpg">/)
  assert.match(html, new RegExp(`<link rel="canonical" href="https://nostrvault.app/p/${npub}">`))
  assert.match(html, new RegExp(`href="nostrvault://p/${npub}">Open in Nostr Vault`))
  assert.match(html, new RegExp(`href="nostr:${npub}">Open in another Nostr app`))
  assert.match(html, /href="\/">Get Nostr Vault/)
  assert.match(html, /hi &lt;script&gt;alert\(1\)&lt;\/script&gt;/)
  assert.doesNotMatch(html, /<script/)
})

test("a key with no profile still gets a working page, named by its npub", () => {
  const html = renderProfile({ target: parseProfileTarget(npub), profile: null })
  assert.match(html, new RegExp(`<title>${npub.slice(0, 12)}…${npub.slice(-6)} on Nostr</title>`))
  assert.match(html, /og-image\.jpg/)
  assert.match(html, new RegExp(`nostrvault://p/${npub}`))
})

test("not a profile: a no-index page that says so", () => {
  const html = renderProfileMissing({ code: "junk" })
  assert.match(html, /isn't a Nostr profile link/)
  assert.match(html, /<meta name="robots" content="noindex">/)
})

test("loadProfile: the newest signed kind 0 of that key, from the link's hints and the profile relays", async () => {
  const old = kind0(alice, { name: "old" }, 100), fresh = kind0(alice, { name: "new" }, 200)
  const forged = { ...kind0(alice, { name: "forged" }, 300), content: JSON.stringify({ name: "tampered" }) }
  const other = kind0(mallory, { name: "mallory" }, 400)
  const asked = []
  const query = async (relays, filter) => { asked.push({ relays, filter }); return [old, forged, other, fresh] }
  const ev = await loadProfile({ pubkey: A, relays: ["wss://hint.example.com", "ws://10.0.0.1"] }, query)
  assert.equal(JSON.parse(ev.content).name, "new")
  assert.deepEqual(asked[0].filter, { kinds: [0], authors: [A], limit: 5 })
  assert.equal(asked[0].relays[0], "wss://hint.example.com")
  assert.ok(!asked[0].relays.includes("ws://10.0.0.1"), "an unsafe hint is never dialled")
  assert.equal(await loadProfile({ pubkey: M, relays: [] }, async () => []), null)
})

test("the /p/ CSP: no script, connects to nothing; nginx proxies /p/ to the thread service", () => {
  const conf = readFileSync(new URL("../../website/nginx.conf", import.meta.url), "utf8")
  const csp = /~\^\/p\/\s+"([^"]+)"/.exec(conf)[1]
  const dir = name => csp.split(";").map(d => d.trim().split(/\s+/)).find(d => d[0] === name)?.slice(1)
  assert.deepEqual(dir("default-src"), ["'none'"])
  assert.equal(dir("script-src"), undefined, "falls back to default-src 'none'")
  assert.equal(dir("connect-src"), undefined)
  assert.match(conf, /location \^~ \/p\/ \{[\s\S]*?proxy_pass \$nv_thread;/)
})
