// The web Global feed against the iPhone's: FeedFilterEngine.filterFeedNotes' `mode == .global` branch (trusted
// authors only, failing closed, no replies) and FeedService.trustScopedFilters (ask for trusted authors, then open).
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { globalShows, filterGlobal } from "../src/net/global-trust.js"
import { fetchStrangerFeed } from "../src/net/feeds.js"
import { TRUSTED_AUTHORS_CAP } from "../src/readers/trust.js"

const swift = path => readFileSync(new URL(`../../HavenApp/HavenApp/${path}`, import.meta.url), "utf8")
const ME = "0".repeat(64), A = "a".repeat(64), B = "b".repeat(64), S = "5".repeat(64)
const note = (id, pubkey, extra = {}) => ({ id, pubkey, kind: 1, created_at: 100, content: "", tags: [], ...extra })
const reply = (id, pubkey) => note(id, pubkey, { tags: [["e", "f".repeat(64), "", "reply"]] })
const trust = new Set([ME, A, B])

test("the Swift Global branch is the rule ported here", () => {
  const src = swift("Services/FeedFilterEngine.swift")
  const branch = src.slice(src.indexOf("if mode == .global {"), src.indexOf("if mode == .following {"))
  // Judged on the signer: a repost's reposter, never the author its content names (PR 1926). The web's note.pubkey
  // is the signer too; trustShows also wants the reposted author in the web (Logen 2026-11-04).
  assert.match(branch, /if globalRequiresTrust && !wotPubkeys\.contains\(note\.repostedBy \?\? note\.pubkey\) \{ return false \}/)
  assert.match(branch, /if note\.isReply \{ return false \}/)
  // Fails closed: the trust set is your saved web plus follows, so with no saved web just your follows, and empty
  // when you follow nobody (PR 1927; the web's globalTrust does the same).
  assert.match(swift("Models/TrustMap.swift"), /static func web\(saved: Set<String>, follows: Set<String>\) -> Set<String> \{\s*saved\.union\(follows\)\s*\}/)
  // The two filters, trusted authors capped first, then open.
  const wot = swift("Services/Feed/FeedService+WebOfTrust.swift")
  assert.match(wot, /byAuthor\["authors"\] = Array\(trust\.sorted\(\)\.prefix\(trustedAuthorsCap\)\)\s*return \[byAuthor, base\]/)
  assert.match(swift("Services/FeedService.swift"), new RegExp(`trustedAuthorsCap = ${TRUSTED_AUTHORS_CAP}\\b`))
})

test("Global shows trusted authors' notes, never a stranger's, never a reply", () => {
  assert.equal(globalShows(note("1", A), trust), true)
  assert.equal(globalShows(note("2", S), trust), false)
  assert.equal(globalShows(reply("3", A), trust), false)
  assert.equal(globalShows(note("4", ME), trust), true)
  // A NIP-22 comment answers a note too.
  assert.equal(globalShows(note("5", A, { kind: 1111, tags: [["e", "f".repeat(64)]] }), trust), false)
})

test("a repost shows only when the reposter and the reposted note's author are both in the web (Logen 2026-11-04)", () => {
  const boostOfStranger = note("r1", A, { kind: 6, content: JSON.stringify(note("x", S)) })
  const strangerBoostsTrusted = note("r2", S, { kind: 6, content: JSON.stringify(note("y", A)) })
  const boostOfTrusted = note("r3", A, { kind: 6, content: JSON.stringify(note("z", A)) })
  const bareBoostOfStranger = note("r4", A, { kind: 6, content: "", tags: [["e", "x"], ["p", S]] })
  assert.deepEqual(filterGlobal([boostOfStranger, strangerBoostsTrusted, boostOfTrusted, bareBoostOfStranger], trust).map(n => n.id), ["r3"])
})

test("no web yet shows nothing: Global fails closed", () => {
  assert.deepEqual(filterGlobal([note("1", A)], null), [])
  assert.deepEqual(filterGlobal([note("1", A)], new Set()), [])
})

test("Global asks for trusted authors then open, and keeps only what Global shows", async () => {
  const asked = []
  const query = async (_r, f) => {
    asked.push(f)
    return f.authors ? [note("t1", A), reply("t2", B)] : [note("o1", S, { created_at: 200 }), note("t1", A), note("o2", B, { created_at: 150 })]
  }
  const got = await fetchStrangerFeed({ mode: "global" }, ["wss://r"], { trust, query })
  assert.deepEqual(got.map(n => n.id), ["o2", "t1"])
  assert.equal(asked.length, 2)
  assert.deepEqual(asked[0].authors, [...trust].sort())
  assert.equal(asked[1].authors, undefined)
})

test("with no web Global and Hashtag ask nothing; Hashtag and Relay keep only the web's notes, replies too (Logen 2026-11-04)", async () => {
  let asked = 0
  const query = async () => { asked++; return [note("h1", S, { tags: [["t", "x"]] }), note("h2", A, { tags: [["t", "x"]] }), note("h3", A, { tags: [["t", "x"], ["e", "root", "", "root"]] })] }
  assert.deepEqual(await fetchStrangerFeed({ mode: "global" }, ["wss://r"], { trust: null, query }), [])
  assert.deepEqual(await fetchStrangerFeed({ mode: "hashtag", tag: "x" }, ["wss://r"], { trust: null, query }), [])
  assert.equal(asked, 0)
  assert.deepEqual((await fetchStrangerFeed({ mode: "hashtag", tag: "x" }, ["wss://r"], { trust, query })).map(n => n.id).sort(), ["h2", "h3"])
  assert.deepEqual((await fetchStrangerFeed({ mode: "relay", relay: "wss://r" }, ["wss://r"], { trust, query })).map(n => n.id).sort(), ["h2", "h3"])
})
