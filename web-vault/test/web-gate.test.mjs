// The one web-of-trust gate (web-gate.js): the 5-step rule, blocks and mutes inside it, judged on the signer and a
// zap's verified request signer, the hop 3 layer, reach, the hop 3 ration, and failing closed.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import {
  webLayers, gateWeb, followsOnlyWeb, noteSubject, zapSubject, judge, judgeNote, isBlockedSubject, capHop3,
  MIN_FOLLOWERS, HOP3_FLOOR, NEW_ACCOUNT_WEB_CAP,
} from "../src/net/web-gate.js"
import { muteSet, isBlockedNote } from "../src/net/blocks.js"

const pk = n => n.toString(16).padStart(64, "0")
const ME = pk(1), ALT = pk(2), STRANGER = pk(999), WHITE = pk(998)
const list = (who, follows) => ({ kind: 3, pubkey: who, created_at: 1, tags: follows.map(f => ["p", f]) })
const note = (pubkey, extra = {}) => ({ id: pk(Math.floor(Math.random() * 1e9) + 5000), kind: 1, pubkey, created_at: 1, content: "hi", tags: [], ...extra })

// 12 follows (>= MIN_FOLLOWERS, so no new-account widening). CLOSE is followed by 10 of them, NEAR by 3.
const FOLLOWS = Array.from({ length: 12 }, (_, i) => pk(100 + i))
const CLOSE = pk(500), NEAR = pk(501)
const LISTS = new Map(FOLLOWS.map((f, i) => [f, list(f, [...(i < 10 ? [CLOSE] : []), ...(i < 3 ? [NEAR] : [])])]))
const layers = () => webLayers({ follows: FOLLOWS, lists: LISTS, own: [ME, ALT] })
const web = (extra = {}) => gateWeb({ own: [ME, ALT], whitelist: [WHITE], ...layers(), ...extra })

test("layers: follows + own + >= Min Followers are the web, fewer is hop 3, nobody else", () => {
  const { web: w, hop3 } = layers()
  assert.equal(MIN_FOLLOWERS, 10)
  for (const f of [...FOLLOWS, ME, ALT, CLOSE]) assert.ok(w.has(f), f)
  assert.ok(!w.has(NEAR) && hop3.has(NEAR))
  assert.ok(!w.has(STRANGER) && !hop3.has(STRANGER))
  assert.ok(!hop3.has(CLOSE))
})

test("layers fail closed: no lists back is the follows and own keys, and nothing one hop out", () => {
  const { web: w, hop3 } = webLayers({ follows: FOLLOWS, lists: new Map(), own: [ME] })
  assert.deepEqual([...w].sort(), [...FOLLOWS, ME].sort())
  assert.equal(hop3.size, 0)
})

test("layers: a new account (fewer follows than the bar) widens to the most-followed, the rest are hop 3", () => {
  const few = FOLLOWS.slice(0, 2)
  const lists = new Map(few.map(f => [f, list(f, [CLOSE, NEAR])]))
  const { web: w } = webLayers({ follows: few, lists })
  assert.ok(w.has(CLOSE) && w.has(NEAR))
  const many = Array.from({ length: NEW_ACCOUNT_WEB_CAP + 3 }, (_, i) => pk(10_000 + i))
  const big = webLayers({ follows: few, lists: new Map([[few[0], list(few[0], many)], [few[1], list(few[1], [many.at(-1)])]]) })
  assert.ok(big.web.has(many.at(-1)), "followed by both follows ranks first")
  assert.equal(big.hop3.size, 3)
})

test("rule: own, always, whitelist and web are inside; everyone else outside on reach web", () => {
  const w = web()
  for (const k of [ME, ALT, WHITE, CLOSE, FOLLOWS[0]]) assert.equal(judgeNote(note(k), w), "inside", k)
  assert.equal(judgeNote(note(NEAR), w), "outside")
  assert.equal(judgeNote(note(STRANGER), w), "outside")
  assert.equal(judgeNote(note(STRANGER), w, { always: [STRANGER] }), "inside")
  assert.equal(judgeNote(note(STRANGER.toUpperCase()), w, { always: [STRANGER] }), "inside", "keys compare lowercased")
})

test("rule: reach everyone lets anyone in, webAndHop3 only hop 3", () => {
  const w = web()
  assert.equal(judgeNote(note(STRANGER), w, { reach: "everyone" }), "inside")
  assert.equal(judgeNote(note(NEAR), w, { reach: "webAndHop3" }), "hop3")
  assert.equal(judgeNote(note(STRANGER), w, { reach: "webAndHop3" }), "outside")
  assert.equal(judgeNote(note(CLOSE), w, { reach: "webAndHop3" }), "inside")
})

test("rule: blocked wins over everything, reach everyone and always included", () => {
  const w = web({ blocked: muteSet([CLOSE, STRANGER]) })
  assert.equal(judgeNote(note(CLOSE), w), "blocked")
  assert.equal(judgeNote(note(STRANGER), w, { reach: "everyone", always: [STRANGER] }), "blocked")
})

test("rule: an own account is never blocked by its own list, but mutes still hide its words", () => {
  const w = web({ blocked: muteSet([ALT], [["word", "airdrop"]]) })
  assert.equal(judgeNote(note(ALT), w), "inside")
  assert.equal(judgeNote(note(ALT, { content: "free AIRDROP" }), w), "blocked")
})

test("rule: muted words, hashtags and threads block, also for a note from the web", () => {
  const thread = pk(7777)
  const w = web({ blocked: muteSet([], [["word", "airdrop"], ["t", "spam"], ["e", thread]]) })
  assert.equal(judgeNote(note(CLOSE, { content: "an Airdrop link" }), w), "blocked")
  assert.equal(judgeNote(note(CLOSE, { tags: [["t", "Spam"]] }), w), "blocked")
  assert.equal(judgeNote(note(CLOSE, { tags: [["e", thread, "", "root"]] }), w), "blocked")
  assert.equal(judgeNote(note(CLOSE), w), "inside")
})

test("judged on the signer: a repost is the reposter's, and a blocked original author blocks it", () => {
  const sk = generateSecretKey(), author = getPublicKey(sk)
  const inner = finalizeEvent({ kind: 1, created_at: 1, tags: [], content: "orig" }, sk)
  const repost = { id: pk(4242), kind: 6, pubkey: FOLLOWS[0], created_at: 2, tags: [["e", inner.id], ["p", author]], content: JSON.stringify(inner) }
  assert.equal(judgeNote(repost, web()), "inside", "a follow reposting a stranger is inside")
  const strangerRepost = { ...repost, id: pk(4243), pubkey: STRANGER }
  assert.equal(judgeNote(strangerRepost, web()), "outside", "a stranger reposting a follow is not")
  assert.equal(judgeNote({ ...repost, id: pk(4244) }, web({ blocked: muteSet([author]) })), "blocked")
  const muted = { ...repost, id: pk(4245) }
  assert.equal(judgeNote(muted, web({ blocked: muteSet([], [["word", "orig"]]) })), "blocked", "the inner note's words")
})

test("a reply to a blocked person's note is blocked when the parent's author is known", () => {
  const parent = pk(8888)
  const reply = note(CLOSE, { tags: [["e", parent, "", "reply"]] })
  const w = web({ blocked: muteSet([STRANGER]) })
  assert.equal(judgeNote(reply, w), "inside")
  assert.equal(judgeNote(reply, w, { authorOf: id => (id === parent ? STRANGER : null) }), "blocked")
})

test("zaps: judged on the verified request signer, never the receipt's", () => {
  const w = web()
  const receipt = { id: pk(31), kind: 9735, pubkey: CLOSE, tags: [] }
  assert.equal(judge(zapSubject(receipt, null), w), "outside", "no verified request: outside, even from a web key")
  assert.equal(judge(zapSubject(receipt, { pubkey: STRANGER, content: "gm" }), w), "outside")
  assert.equal(judge(zapSubject(receipt, { pubkey: FOLLOWS[1], content: "gm" }), w), "inside")
  const bw = web({ blocked: muteSet([], [["word", "airdrop"]]) })
  assert.equal(judge(zapSubject(receipt, { pubkey: FOLLOWS[1], content: "claim airdrop" }), bw), "blocked", "the comment is muted")
})

test("fail closed: the follows-only web lets in you and your follows only", () => {
  const w = followsOnlyWeb({ me: ME, follows: FOLLOWS })
  assert.equal(judgeNote(note(ME), w), "inside")
  assert.equal(judgeNote(note(FOLLOWS[3]), w), "inside")
  assert.equal(judgeNote(note(CLOSE), w), "outside")
  assert.equal(judgeNote(note(CLOSE), w, { reach: "webAndHop3" }), "outside")
  assert.equal(judge({ signer: "", related: [], muted: [], refs: [] }, w, { reach: "everyone" }), "outside", "nobody named is never inside")
})

test("isBlockedNote (blocks.js) is the gate's step 1", () => {
  const blocked = muteSet([STRANGER], [["word", "airdrop"]])
  for (const ev of [note(STRANGER), note(CLOSE, { content: "airdrop" }), note(CLOSE)]) {
    assert.equal(isBlockedNote(ev, blocked), isBlockedSubject(noteSubject(ev), gateWeb({ blocked })))
  }
})

test("capHop3: one per author, no replies, at most max(floor, others/5), order kept, others untouched", () => {
  const rows = []
  for (let i = 0; i < 60; i++) rows.push({ v: "inside", a: `in${i}` })
  for (let i = 0; i < 20; i++) rows.push({ v: "hop3", a: `h${i % 15}`, reply: i === 0 })
  rows.push({ v: "outside", a: "o" })
  const out = capHop3(rows, { verdict: r => r.v, author: r => r.a, isReply: r => !!r.reply })
  const hop = out.filter(r => r.v === "hop3")
  assert.equal(hop.length, Math.max(HOP3_FLOOR, Math.floor(61 / 5)))
  assert.ok(!hop.some(r => r.reply))
  assert.equal(new Set(hop.map(r => r.a)).size, hop.length)
  assert.equal(out.filter(r => r.v !== "hop3").length, 61)
  assert.deepEqual(out.filter(r => r.v === "inside").map(r => r.a), rows.filter(r => r.v === "inside").map(r => r.a))
})
